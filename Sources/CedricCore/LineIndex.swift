import Foundation

/// The UTF-16 offset of the start of every line, kept up to date
/// incrementally as the text changes. Lines end in "\n" only: Cedric
/// normalises CRLF and CR on load and paste and writes the document's line
/// ending back on save.
public struct LineIndex: Sendable {
    /// `starts[i]` is where line i begins; `starts[0] == 0`. Always at
    /// least one line (an empty document has one empty line). Four bytes
    /// a line (LineStarts): a 1 GB log's 14.6 M lines took 117 MB as Ints.
    public private(set) var starts: LineStarts = [0]
    public private(set) var length: Int = 0

    public init() {}

    /// `expectedLineCount`: how many lines the text has, when the caller
    /// already counted its newlines (a decode's scan), for an exact
    /// reservation instead of a guess of one line per 40 units (214 MB of
    /// address space for a 1 GB log, 10 MB for a one-line 50 MB file).
    /// Only a capacity hint: a wrong count costs a reallocation, never a
    /// wrong index.
    public init(_ text: NSString, expectedLineCount: Int? = nil) {
        length = text.length
        starts = [0]
        starts.reserveCapacity(expectedLineCount.map { max(1, $0) } ?? max(16, length / 40))
        // 8-bit ASCII text: memchr over its bytes; the rest (all of
        // UTF-16 text) a unit at a time.
        let done = Self.scanASCIIPrefix(text) { starts.append($0) }
        Self.scanNewlines(text, in: NSRange(location: done, length: length - done)) { starts.append($0) }
    }

    public var lineCount: Int { starts.count }

    /// The length of the longest line (newline included), O(lines).
    public var longestLine: Int {
        var best = 0
        for i in 0..<starts.count {
            let end = i + 1 < starts.count ? starts[i + 1] : length
            best = max(best, end - starts[i])
        }
        return best
    }

    /// Line `i`'s length, newline included.
    public func lineLength(_ i: Int) -> Int {
        (i + 1 < starts.count ? starts[i + 1] : length) - starts[i]
    }

    /// How many units `scanASCIIPrefix` copies out at a time when the
    /// text has no C-string pointer.
    static let asciiChunk = 1 << 20

    /// Text stored as 8-bit ASCII (a large decode reading the file's bytes
    /// in place, a native ASCII Swift string, an 8-bit CFString): calls
    /// `found` with the offset just after each "\n", found with `memchr`
    /// over the bytes, and returns how many units from the start it
    /// scanned (all of them, unless a copy stops short). One ASCII byte is
    /// one UTF-16 unit, so the offsets are those `scanNewlines` gives.
    /// Text stored as UTF-16 (or not ASCII) returns 0 at once, having
    /// called nothing: `scanNewlines` reads it in its own form faster.
    static func scanASCIIPrefix(_ text: NSString, _ found: (Int) -> Void) -> Int {
        let length = text.length
        guard length > 0, CFStringGetFastestEncoding(text as CFString) == CFStringBuiltInEncodings.ASCII.rawValue else { return 0 }
        if scanASCIIPointer(text, found) { return length }
        return scanASCIIBytes(text, found)
    }

    /// The bytes in place, when the text hands out a C-string pointer (a
    /// NUL-terminated 8-bit string: a native Swift string, most CFStrings).
    /// False, having called nothing, when it doesn't.
    static func scanASCIIPointer(_ text: NSString, _ found: (Int) -> Void) -> Bool {
        withExtendedLifetime(text) {
            let length = text.length
            guard let cstr = CFStringGetCStringPtr(text as CFString, CFStringBuiltInEncodings.ASCII.rawValue) else { return false }
            let base = UnsafeRawPointer(cstr)
            var pos = 0
            while pos < length, let hit = memchr(base + pos, 10, length - pos) {
                let at = UnsafeRawPointer(hit) - base
                found(at + 1)
                pos = at + 1
            }
            return true
        }
    }

    /// Copies of the bytes, `asciiChunk` at a time (a string reading a
    /// file's bytes in place has no terminating NUL, so no C-string
    /// pointer). Stops where a copy converts fewer units than asked or
    /// not one byte per unit; returns how many units it scanned.
    static func scanASCIIBytes(_ text: NSString, _ found: (Int) -> Void) -> Int {
        let length = text.length
        guard length > 0 else { return 0 }
        let room = min(asciiChunk, length)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: room)
        defer { buffer.deallocate() }
        let cf = text as CFString
        var pos = 0
        while pos < length {
            let want = min(room, length - pos)
            var used = 0
            let got = CFStringGetBytes(cf, CFRange(location: pos, length: want), CFStringBuiltInEncodings.ASCII.rawValue,
                                       0, false, buffer, want, &used)
            guard got > 0, got <= want, used == got else { break }
            var k = 0
            while k < got, let hit = memchr(buffer + k, 10, got - k) {
                let at = UnsafeMutableRawPointer(hit) - UnsafeMutableRawPointer(buffer)
                found(pos + at + 1)
                k = at + 1
            }
            pos += got
            if got < want { break }
        }
        return pos
    }

    /// Calls `found` with the offset just after each "\n" in `range`.
    /// The scratch buffer is the size of the range, up to 64 K units: an
    /// edit of one character asks for 2 bytes, not 128 KB.
    static func scanNewlines(_ text: NSString, in range: NSRange, _ found: (Int) -> Void) {
        guard range.length > 0 else { return }
        let chunk = min(65536, range.length)
        var buffer = [UInt16](repeating: 0, count: chunk)
        var pos = range.location
        let end = range.location + range.length
        while pos < end {
            let len = min(chunk, end - pos)
            buffer.withUnsafeMutableBufferPointer { p in
                text.getCharacters(p.baseAddress!, range: NSRange(location: pos, length: len))
                for k in 0..<len where p[k] == 10 { found(pos + k + 1) }
            }
            pos += len
        }
    }

    /// The line containing `offset` (the last line for offset == length).
    public func line(containing offset: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Line `i`'s range without its "\n".
    public func contentRange(ofLine i: Int) -> NSRange {
        let start = starts[i]
        let end = i + 1 < starts.count ? starts[i + 1] - 1 : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// Updates the index after `text` (already edited) had `oldRange`
    /// replaced by `newLength` characters. Returns the first line whose
    /// content changed, for the highlighter's invalidation.
    @discardableResult
    public mutating func replace(_ oldRange: NSRange, newLength: Int, in text: NSString) -> Int {
        let delta = newLength - oldRange.length
        let firstLine = line(containing: oldRange.location)
        // Lines whose starts fall inside the replaced range are gone.
        var removeEnd = firstLine + 1
        while removeEnd < starts.count, starts[removeEnd] <= oldRange.location + oldRange.length { removeEnd += 1 }
        var inserted: [Int] = []
        Self.scanNewlines(text, in: NSRange(location: oldRange.location, length: newLength)) { inserted.append($0) }
        if delta != 0 { starts.shift(from: removeEnd, by: delta) }
        starts.replaceSubrange((firstLine + 1)..<removeEnd, with: inserted)
        length += delta
        return firstLine
    }
}

/// The line starts of a LineIndex: Ints to their users, kept as UInt32
/// while every start fits (a text under 4 G UTF-16 units, so any file
/// Owlink opens in practice), as Ints from the first one that doesn't.
public struct LineStarts: RandomAccessCollection, Equatable, Sendable, ExpressibleByArrayLiteral {
    /// The starts while they all fit in 32 bits; empty once `wide` is used.
    private var narrow: [UInt32] = []
    /// All the starts, once one didn't fit in `narrow`.
    private var wide: [Int] = []
    /// `wide` holds the starts (one start, or a shift, passed UInt32.max).
    private(set) var isWide = false

    public init() {}
    public init(arrayLiteral elements: Int...) {
        self.init()
        reserveCapacity(elements.count)
        for e in elements { append(e) }
    }
    public init<S: Sequence>(_ elements: S) where S.Element == Int {
        self.init()
        for e in elements { append(e) }
    }

    public var startIndex: Int { 0 }
    public var endIndex: Int { isWide ? wide.count : narrow.count }
    public var count: Int { endIndex }

    public subscript(i: Int) -> Int {
        isWide ? wide[i] : Int(narrow[i])
    }

    static func fits(_ v: Int) -> Bool { v >= 0 && v <= Int(UInt32.max) }

    /// From here on as Ints.
    private mutating func widen() {
        guard !isWide else { return }
        wide = narrow.map { Int($0) }
        narrow = []
        isWide = true
    }

    public mutating func reserveCapacity(_ n: Int) {
        if isWide { wide.reserveCapacity(n) } else { narrow.reserveCapacity(n) }
    }

    public mutating func append(_ v: Int) {
        if !isWide, Self.fits(v) { narrow.append(UInt32(v)); return }
        widen()
        wide.append(v)
    }

    /// Adds `delta` to every start from `index` on (an edit before them).
    mutating func shift(from index: Int, by delta: Int) {
        guard delta != 0, index < count else { return }
        if !isWide, let last = narrow.last, Self.fits(Int(last) + delta), Self.fits(Int(narrow[index]) + delta) {
            // Starts increase, so the first and last bound the rest.
            if delta > 0 {
                let d = UInt32(delta)
                for k in index..<narrow.count { narrow[k] += d }
            } else {
                let d = UInt32(-delta)
                for k in index..<narrow.count { narrow[k] -= d }
            }
            return
        }
        widen()
        for k in index..<wide.count { wide[k] += delta }
    }

    mutating func replaceSubrange(_ range: Range<Int>, with new: [Int]) {
        if !isWide, new.allSatisfy(Self.fits) {
            narrow.replaceSubrange(range, with: new.map { UInt32($0) })
            return
        }
        widen()
        wide.replaceSubrange(range, with: new)
    }

    /// Whether `other` keeps its starts in the very same storage as this
    /// one (checks: the same index, not a copy). Empty starts share
    /// nothing. The addresses are compared only while both are borrowed.
    public func sharesStorage(with other: LineStarts) -> Bool {
        guard isWide == other.isWide else { return false }
        func same<T>(_ a: [T], _ b: [T]) -> Bool {
            a.withUnsafeBufferPointer { pa in
                b.withUnsafeBufferPointer { pb in
                    pa.count > 0 && pa.count == pb.count && pa.baseAddress != nil && pa.baseAddress == pb.baseAddress
                }
            }
        }
        return isWide ? same(wide, other.wide) : same(narrow, other.narrow)
    }

    public static func == (a: LineStarts, b: LineStarts) -> Bool {
        if !a.isWide, !b.isWide { return a.narrow == b.narrow }
        return a.elementsEqual(b)
    }
}
