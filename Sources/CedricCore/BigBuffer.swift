import Darwin

/// Memory for a big buffer (a large file's bytes, or its text with CRLF
/// made LF) that goes back to the system the moment it is freed.
///
/// Why not malloc: a freed large malloc block is handed to the system's
/// deferred reclaim and stays resident, and counted in the app's
/// footprint, until the system gets round to it. Opening a 1 GB file
/// freed its 1 GB read buffer once the text was in the tab's storage,
/// and the app still showed 2.27 GB seconds later (the storage plus the
/// freed buffer). Mapped anonymously and unmapped when freed, it is gone
/// at once.
///
/// The memory is the process's own (private, anonymous, zero-filled):
/// never a file mapping, so nothing another process writes shows through.
public enum BigBuffer {
    /// Buffers at least this big (bytes) are mapped; smaller ones use malloc.
    public static let minimum = 16 * 1024 * 1024

    /// The tag vmmap and footprint show the mapping under ("Memory Tag 240").
    static let tag = Int32(240) << 24 // VM_MAKE_TAG(VM_MEMORY_APPLICATION_SPECIFIC_1)

    /// Room for `count` bytes (at least 1), from malloc below `minimum`,
    /// else mapped. Nil if there's no room. Free it with `free(_:count:)`
    /// and the same `count`.
    public static func allocate(_ count: Int) -> UnsafeMutableRawPointer? {
        let n = max(count, 1)
        guard n >= minimum else { return malloc(n) }
        let p = mmap(nil, n, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, tag, 0)
        return p == MAP_FAILED ? nil : p
    }

    /// Frees what `allocate(count)` gave.
    public static func free(_ p: UnsafeMutableRawPointer, count: Int) {
        let n = max(count, 1)
        if n >= minimum { munmap(p, n) } else { Darwin.free(p) }
    }

    /// `p` (room for `count` bytes, from `allocate`) with room for
    /// `newCount`, its first `min(count, newCount)` bytes kept. On failure
    /// nil, and `p` is untouched (still to be freed).
    public static func grow(_ p: UnsafeMutableRawPointer, count: Int, to newCount: Int) -> UnsafeMutableRawPointer? {
        if max(count, 1) < minimum, max(newCount, 1) < minimum { return realloc(p, max(newCount, 1)) }
        guard let q = allocate(newCount) else { return nil }
        memcpy(q, p, min(count, newCount))
        free(p, count: count)
        return q
    }
}
