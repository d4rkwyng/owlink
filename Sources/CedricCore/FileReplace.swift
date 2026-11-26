import CryptoKit
import Foundation

/// Replace in Files: a preview (`ReplacePlan`, computed from the files the
/// search found, off the main thread), then the writes, then an undo.
///
/// Data safety, in order:
/// - a file is planned only if its bytes decode and re-encode to exactly
///   the same bytes (encoding, BOM, line endings), so the write changes
///   nothing but the replaced spans; mixed line endings are skipped;
/// - a file changed since the search (date, size) is skipped at preview,
///   and one changed since the preview (date, size, SHA-256) at the write;
/// - every target's original bytes are copied to the undo store before
///   the first write;
/// - writes are atomic (a temp file in the same folder, renamed over the
///   file) and keep the file's mode, ACL and extended attributes; the
///   file gets a new modification date; symbolic links, hard-linked files,
///   read-only files, anything inside a .git folder (or a .git file) and
///   files outside the searched folder are refused;
/// - a file whose encoding is a guess at an 8-bit one (Latin-1,
///   Windows-1252, Mac Roman) is skipped when the replacement has
///   non-ASCII text or the bytes hold UTF-8 sequences: it may be UTF-8
///   with a stray byte, and the write would mix encodings;
/// - files open in a tab are not written at all: the app edits their
///   buffer (one ⌘Z there), from the tab's own text.
public struct ReplaceQuery: Sendable, Equatable, Codable {
    public var query: String
    public var template: String
    public var regex: Bool
    public var caseSensitive: Bool

    public init(query: String, template: String, regex: Bool = false, caseSensitive: Bool = false) {
        self.query = query
        self.template = template
        self.regex = regex
        self.caseSensitive = caseSensitive
    }

    public var findOptions: FindOptions { FindOptions(regex: regex, caseSensitive: caseSensitive) }
}

/// One replacement in a file's (LF-normalised) text.
public struct ReplaceEdit: Sendable, Equatable {
    public var range: NSRange
    public var replacement: String
    /// 1-based.
    public var line: Int
    /// The line before the edit, cut to 400 characters around the match.
    public var lineText: String
    /// The match within `lineText`.
    public var lineRange: NSRange
}

/// Why a file is left out of a replace.
public enum ReplaceSkip: String, Sendable, Codable, CaseIterable {
    case binary, tooLarge, mixedLineEndings, notRoundTrip, cannotEncode
    case changedSinceSearch, changedSincePreview, changedSinceReplace
    case unreadable, unwritable, outsideFolder, symbolicLink, hardLinked, readOnlyTab
    case readOnly, encodingUncertain, insideGit
    /// Undo: the backup copy of the original couldn't be read, or isn't
    /// what was backed up. The operation stays open for another try.
    case backupUnreadable

    public var summary: String {
        switch self {
        case .binary: return String(localized: "binary")
        case .tooLarge: return String(localized: "over 20 MB")
        case .mixedLineEndings: return String(localized: "mixed line endings (open it to replace there)")
        case .notRoundTrip: return String(localized: "encoding wouldn’t round-trip")
        case .cannotEncode: return String(localized: "replacement not encodable")
        case .changedSinceSearch: return String(localized: "changed since search")
        case .changedSincePreview: return String(localized: "changed since preview")
        case .changedSinceReplace: return String(localized: "changed since the replace")
        case .unreadable: return String(localized: "unreadable")
        case .unwritable: return String(localized: "couldn’t write")
        case .outsideFolder: return String(localized: "outside the folder")
        case .symbolicLink: return String(localized: "symbolic link")
        case .hardLinked: return String(localized: "hard-linked")
        case .readOnlyTab: return String(localized: "read-only tab")
        case .readOnly: return String(localized: "read-only")
        case .encodingUncertain: return String(localized: "encoding uncertain")
        case .insideGit: return String(localized: "inside .git")
        case .backupUnreadable: return String(localized: "backup copy unreadable")
        }
    }
}

public struct SkippedFile: Sendable, Equatable {
    public var url: URL
    public var relativePath: String
    public var reason: ReplaceSkip
    /// Why, when the reason alone doesn't say (the error behind
    /// `backupUnreadable`).
    public var detail: String?

    public init(url: URL, relativePath: String, reason: ReplaceSkip, detail: String? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.reason = reason
        self.detail = detail
    }

    /// "backup copy unreadable: permission denied", or the reason alone.
    public var why: String { detail.map { "\(reason.summary): \($0)" } ?? reason.summary }
}

/// What a planned file looked like on disk at preview time.
public struct DiskSource: Sendable, Equatable {
    public var stamp: DiskStamp
    public var sha256: Data
    public var encoding: TextEncoding
    public var lineEnding: LineEnding
}

public struct ReplaceFile: Sendable {
    public var url: URL
    public var relativePath: String
    /// The text the edits apply to: the decoded file, or the open tab's.
    public var sourceText: String
    public var edits: [ReplaceEdit]
    /// Nil when planned against an open tab's text.
    public var disk: DiskSource?
}

public struct ReplacePlan: Sendable {
    public var query: ReplaceQuery
    public var root: URL
    public var files: [ReplaceFile]
    public var skipped: [SkippedFile]
    public var cancelled = false

    public var replacementCount: Int { files.reduce(0) { $0 + $1.edits.count } }

    public func skippedCount(_ r: ReplaceSkip) -> Int { skipped.filter { $0.reason == r }.count }
}

public struct ReplaceReport: Sendable {
    public var written: [URL] = []
    public var replacements = 0
    public var skipped: [SkippedFile] = []
    /// The undo store operation, if anything was written.
    public var operation: UUID?

    public init() {}
}

/// How far `FileReplace.apply` has got: each file checked again, the
/// originals backed up, each file written. `total` is the number of files
/// in that stage.
public struct ReplaceProgress: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case checking, backingUp, writing, restoring }
    public var stage: Stage
    public var done: Int
    public var total: Int

    public init(stage: Stage, done: Int, total: Int) {
        self.stage = stage
        self.done = done
        self.total = total
    }
}

public enum FileReplace {
    // MARK: Pure

    /// Every non-empty match of `regex` in `text` and its replacement, as
    /// the find bar's Replace All makes them (`FindEngine.replacement`).
    public static func edits(in text: String, regex: NSRegularExpression, query: ReplaceQuery) -> [ReplaceEdit] {
        let ns = text as NSString
        let found = FindEngine.matches(regex, in: ns)
        guard !found.isEmpty else { return [] }
        let index = LineIndex(ns)
        return found.map { m in
            let rep = FindEngine.replacement(for: m, in: ns, template: query.template, regex: regex, options: query.findOptions)
            let line = index.line(containing: m.range.location)
            let content = index.contentRange(ofLine: line)
            var lineText = ns.substring(with: content)
            var loc = m.range.location - content.location
            let len = min(m.range.length, max(0, content.length - loc))
            let lineLen = (lineText as NSString).length
            if lineLen > 400 {
                let shift = max(0, min(loc - 100, lineLen - 400))
                lineText = (lineText as NSString).substring(with: NSRange(location: shift, length: 400))
                loc -= shift
            }
            let lr = NSRange(location: loc, length: min(len, max(0, (lineText as NSString).length - loc)))
            return ReplaceEdit(range: m.range, replacement: rep, line: line + 1, lineText: lineText, lineRange: lr)
        }
    }

    /// `text` with `edits` (sorted, non-overlapping) applied.
    public static func applying(_ edits: [ReplaceEdit], to text: String) -> String {
        let out = NSMutableString(string: text)
        for e in edits.sorted(by: { $0.range.location > $1.range.location }) {
            out.replaceCharacters(in: e.range, with: e.replacement)
        }
        return out as String
    }

    /// The span covering every edit and its new text, for one undoable
    /// buffer change.
    public static func span(_ edits: [ReplaceEdit], in text: String) -> (NSRange, String)? {
        let sorted = edits.sorted { $0.range.location < $1.range.location }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        let ns = text as NSString
        guard NSMaxRange(span) <= ns.length else { return nil }
        let shifted = sorted.map { e -> ReplaceEdit in
            var e = e
            e.range.location -= span.location
            return e
        }
        return (span, applying(shifted, to: ns.substring(with: span)))
    }

    public static func sha256(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }

    /// Same date (within DiskStamp's tolerance) and same size.
    static func same(_ a: DiskStamp, _ b: DiskStamp) -> Bool {
        !DiskStamp.changed(known: a, current: b) && a.size == b.size && (a.modified == nil) == (b.modified == nil)
    }

    // MARK: Plan

    /// One file the search found.
    public struct Candidate: Sendable {
        public var url: URL
        public var relativePath: String
        /// The file's stamp when it was searched (nil: don't compare).
        public var searchStamp: DiskStamp?

        public init(url: URL, relativePath: String, searchStamp: DiskStamp?) {
            self.url = url
            self.relativePath = relativePath
            self.searchStamp = searchStamp
        }
    }

    /// Plans the replace. `buffers`: the text of files open in a tab, by
    /// standardized path; those are planned against that text, not disk.
    /// Reads files; call it off the main thread.
    public static func plan(_ query: ReplaceQuery, root: URL, candidates: [Candidate], buffers: [String: String] = [:],
                            maxFileSize: Int = 20 * 1024 * 1024, isCancelled: () -> Bool = { false }) throws -> ReplacePlan {
        let re = try FindEngine.regex(query.query, query.findOptions)
        var plan = ReplacePlan(query: query, root: root, files: [], skipped: [])
        for c in candidates {
            if isCancelled() { plan.cancelled = true; break }
            func skip(_ r: ReplaceSkip) { plan.skipped.append(SkippedFile(url: c.url, relativePath: c.relativePath, reason: r)) }
            let key = c.url.standardizedFileURL.path
            if let text = buffers[key] {
                let edits = edits(in: text, regex: re, query: query)
                if !edits.isEmpty { plan.files.append(ReplaceFile(url: c.url, relativePath: c.relativePath, sourceText: text, edits: edits, disk: nil)) }
                continue
            }
            if let refusal = refusal(c.url, root: root) { skip(refusal); continue }
            guard let stamp = DiskStamp.of(c.url) else { skip(.unreadable); continue }
            if let s = c.searchStamp, !same(s, stamp) {
                skip(.changedSinceSearch); continue
            }
            if (stamp.size ?? 0) > maxFileSize { skip(.tooLarge); continue }
            guard let data = try? Data(contentsOf: c.url) else { skip(.unreadable); continue }
            if FileSearch.looksBinary(data) { skip(.binary); continue }
            guard let decoded = TextCodec.decode(data) else { skip(.binary); continue }
            if decoded.mixedLineEndings { skip(.mixedLineEndings); continue }
            guard TextCodec.encode(decoded.text, encoding: decoded.encoding, lineEnding: decoded.lineEnding) == data else {
                skip(.notRoundTrip); continue
            }
            let edits = edits(in: decoded.text, regex: re, query: query)
            guard !edits.isEmpty else { continue }
            let replacements = edits.map(\.replacement).joined()
            if !TextCodec.canEncode(replacements, as: decoded.encoding) { skip(.cannotEncode); continue }
            if encodingUncertain(decoded.encoding, data: data, replacements: replacements) { skip(.encodingUncertain); continue }
            plan.files.append(ReplaceFile(url: c.url, relativePath: c.relativePath, sourceText: decoded.text, edits: edits,
                                          disk: DiskSource(stamp: stamp, sha256: sha256(data), encoding: decoded.encoding,
                                                           lineEnding: decoded.lineEnding)))
        }
        return plan
    }

    /// Whether an 8-bit `encoding` (a guess: no BOM, not valid UTF-8) is
    /// too uncertain to write: the replacement has non-ASCII text, or the
    /// bytes hold well-formed UTF-8 multibyte sequences (UTF-8 with a stray
    /// byte, which would end up with two encodings in one file).
    static func encodingUncertain(_ encoding: TextEncoding, data: Data, replacements: String) -> Bool {
        switch encoding {
        case .latin1, .windows1252, .macRoman:
            return !replacements.unicodeScalars.allSatisfy(\.isASCII) || containsUTF8Multibyte(data)
        case .utf8, .utf8BOM, .utf16LE, .utf16BE:
            return false
        }
    }

    /// Whether `data` holds at least one well-formed UTF-8 multibyte sequence.
    static func containsUTF8Multibyte(_ data: Data) -> Bool {
        data.withUnsafeBytes { (b: UnsafeRawBufferPointer) -> Bool in
            let n = b.count
            var i = 0
            func cont(_ k: Int, _ lo: UInt8 = 0x80, _ hi: UInt8 = 0xBF) -> Bool { k < n && b[k] >= lo && b[k] <= hi }
            while i < n {
                let c = b[i]
                if c < 0x80 { i += 1; continue }
                switch c {
                case 0xC2...0xDF: if cont(i + 1) { return true }
                case 0xE0: if cont(i + 1, 0xA0) && cont(i + 2) { return true }
                case 0xE1...0xEC, 0xEE, 0xEF: if cont(i + 1) && cont(i + 2) { return true }
                case 0xED: if cont(i + 1, 0x80, 0x9F) && cont(i + 2) { return true }
                case 0xF0: if cont(i + 1, 0x90) && cont(i + 2) && cont(i + 3) { return true }
                case 0xF1...0xF3: if cont(i + 1) && cont(i + 2) && cont(i + 3) { return true }
                case 0xF4: if cont(i + 1, 0x80, 0x8F) && cont(i + 2) && cont(i + 3) { return true }
                default: break
                }
                i += 1
            }
            return false
        }
    }

    /// Whether `url` is a .git file or inside a .git folder (anywhere on
    /// its path): never written, whatever the Exclude field says.
    static func isInsideGit(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains(".git")
    }

    /// Why `url` may not be written: a symbolic link, hard-linked, not a
    /// regular file, inside .git, (links resolved) outside `root`, or
    /// read-only.
    static func refusal(_ url: URL, root: URL) -> ReplaceSkip? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return .unreadable }
        if st.st_mode & S_IFMT == S_IFLNK { return .symbolicLink }
        guard st.st_mode & S_IFMT == S_IFREG else { return .unreadable }
        if st.st_nlink > 1 { return .hardLinked }
        if isInsideGit(url) { return .insideGit }
        guard SafePaths.isInside(url, root) else { return .outsideFolder }
        // The rename needs only a writable folder: honour the file's own permission.
        if access(url.path, W_OK) != 0 { return .readOnly }
        return nil
    }

    // MARK: Apply (disk)

    /// Writes the planned disk files (`files` with `disk` set and only the
    /// edits to make). Each is checked again (date, size, SHA-256) first;
    /// every original goes to `store` before the first write. Files open
    /// in a tab (`disk == nil`) are ignored here: the app edits those.
    /// Reads, hashes and writes files: the app calls it off the main
    /// thread, one at a time, and shows `progress` (called on the calling
    /// thread after each file of each stage).
    public static func apply(_ files: [ReplaceFile], query: ReplaceQuery, root: URL, store: ReplaceUndoStore,
                             progress: (ReplaceProgress) -> Void = { _ in }) -> ReplaceReport {
        var report = ReplaceReport()
        struct Prepared { var file: ReplaceFile; var original: Data; var new: Data; var mode: mode_t; var count: Int }
        var ready: [Prepared] = []
        let targets = files.filter { $0.disk != nil && !$0.edits.isEmpty }
        for (n, f) in targets.enumerated() {
            defer { progress(ReplaceProgress(stage: .checking, done: n + 1, total: targets.count)) }
            guard let disk = f.disk, !f.edits.isEmpty else { continue }
            func skip(_ r: ReplaceSkip) { report.skipped.append(SkippedFile(url: f.url, relativePath: f.relativePath, reason: r)) }
            if let refusal = refusal(f.url, root: root) { skip(refusal); continue }
            guard let now = DiskStamp.of(f.url), let data = try? Data(contentsOf: f.url) else { skip(.unreadable); continue }
            guard same(disk.stamp, now), sha256(data) == disk.sha256 else { skip(.changedSincePreview); continue }
            guard let new = TextCodec.encode(applying(f.edits, to: f.sourceText), encoding: disk.encoding, lineEnding: disk.lineEnding) else {
                skip(.cannotEncode); continue
            }
            var st = stat()
            guard stat(f.url.path, &st) == 0 else { skip(.unreadable); continue }
            ready.append(Prepared(file: f, original: data, new: new, mode: st.st_mode & 0o7777, count: f.edits.count))
        }
        guard !ready.isEmpty else { return report }
        sweepTempFiles(for: ready.map(\.file.url))

        // The originals, all of them, before the first write.
        let op: ReplaceUndoStore.Operation
        do {
            op = try store.begin(query: query, root: root)
            for (k, p) in ready.enumerated() {
                try op.backup(p.original, index: k, for: p.file.url, written: p.new, mode: p.mode)
                progress(ReplaceProgress(stage: .backingUp, done: k + 1, total: ready.count))
            }
            try op.save()
        } catch {
            for p in ready { report.skipped.append(SkippedFile(url: p.file.url, relativePath: p.file.relativePath, reason: .unwritable)) }
            return report
        }

        for (k, p) in ready.enumerated() {
            defer { progress(ReplaceProgress(stage: .writing, done: k + 1, total: ready.count)) }
            // Last look just before the rename.
            guard let now = DiskStamp.of(p.file.url), let disk = p.file.disk, same(disk.stamp, now) else {
                op.drop(index: k)
                report.skipped.append(SkippedFile(url: p.file.url, relativePath: p.file.relativePath, reason: .changedSincePreview))
                continue
            }
            do {
                try atomicWrite(p.new, to: p.file.url, mode: p.mode, root: root)
                op.noteWritten(index: k, stamp: DiskStamp.of(p.file.url))
                report.written.append(p.file.url)
                report.replacements += p.count
            } catch {
                op.drop(index: k)
                // Made read-only after the checks: said as at the preview.
                let reason: ReplaceSkip = error is TreeWrite.ReadOnly ? .readOnly : .unwritable
                report.skipped.append(SkippedFile(url: p.file.url, relativePath: p.file.relativePath, reason: reason))
            }
        }
        try? op.save()
        report.operation = report.written.isEmpty ? nil : op.id
        return report
    }

    /// The suffix of `atomicWrite`'s temp files: `.<name>.owlink-XXXXXX`.
    static let tempMarker = ".owlink-"

    /// Removes temp files a crashed or killed write left next to `urls`
    /// (`.<name>.owlink-XXXXXX` for one of those names, a regular file
    /// owned by this user, over a minute old). One listing per folder.
    static func sweepTempFiles(for urls: [URL], now: Date = Date()) {
        var byDir: [String: Set<String>] = [:]
        for u in urls { byDir[u.deletingLastPathComponent().path, default: []].insert(u.lastPathComponent) }
        let fm = FileManager.default
        for (dir, names) in byDir {
            guard let items = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for item in items where item.hasPrefix(".") {
                guard let r = item.range(of: tempMarker, options: .backwards) else { continue }
                let suffix = item[r.upperBound...]
                let name = String(item[item.index(after: item.startIndex)..<r.lowerBound])
                guard suffix.count == 6, suffix.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }), names.contains(name) else { continue }
                let path = dir + "/" + item
                var st = stat()
                guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid(),
                      now.timeIntervalSince1970 - Double(st.st_mtimespec.tv_sec) > 60 else { continue }
                unlink(path)
            }
        }
    }

    /// Replaces `url`'s contents atomically: a temp file in the same folder
    /// (so the rename can't cross volumes) gets the bytes, then the file's
    /// ACL and extended attributes (copyfile) and exactly its mode, then is
    /// renamed over it. Not its dates: the new contents get a new
    /// modification date, so rsync, make and other editors see the change.
    ///
    /// With `root`, the folders from `root` down to the file are opened one
    /// at a time without following symbolic links, and the temp file, the
    /// checks and the rename all happen relative to that open folder: a
    /// folder on the way swapped for a link after the checks (to send the
    /// write outside `root`) makes the write fail instead (security review
    /// 0.2.1). Without `root`, only the file's own folder is opened.
    public static func atomicWrite(_ data: Data, to url: URL, mode: mode_t, root: URL? = nil) throws {
        let dirfd: Int32
        if let root {
            guard let rel = TreeWrite.relativeDirectories(of: url, under: root) else { throw CocoaError(.fileWriteNoPermission) }
            dirfd = TreeWrite.openDirectory(root: root.standardizedFileURL.path, components: rel)
        } else {
            dirfd = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        }
        guard dirfd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(dirfd) }
        try TreeWrite.replace(data, name: url.lastPathComponent, in: dirfd, mode: mode)
    }
}

/// File writes relative to an open folder (openat/renameat), for Replace
/// in Files and its undo.
enum TreeWrite {
    /// The file isn't writable (read-only now) at the last check before
    /// the rename; nothing was changed.
    struct ReadOnly: Error {}

    /// The folder names from `root` down to `url`'s folder (empty when the
    /// file is directly in `root`); nil when `url` isn't under `root` as
    /// written (or under `root` with its own links resolved). By the paths'
    /// bytes (`FolderTree.relativePath`, `FolderTree.components`): comparing
    /// path components as Swift text calls canonically equivalent but
    /// byte-distinct folders the same; each folder is one name to the
    /// kernel (`Beneath.isName`).
    static func relativeDirectories(of url: URL, under root: URL) -> [String]? {
        for base in [root.standardizedFileURL, root.standardizedFileURL.resolvingSymlinksInPath()] {
            guard let rel = FolderTree.relativePath(of: url, in: base), !rel.isEmpty else { continue }
            let dirs = Array(FolderTree.components(rel).dropLast())
            guard dirs.allSatisfy(Beneath.isName) else { return nil }
            return dirs
        }
        return nil
    }

    /// `root` (its own path may hold links: the folder the user chose),
    /// then each of `components` with O_NOFOLLOW: a link anywhere below
    /// `root` fails the open. Returns the last folder's descriptor, or -1.
    static func openDirectory(root: String, components: [String]) -> Int32 {
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return -1 }
        for c in components {
            let next = openat(fd, c, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return -1 }
            fd = next
        }
        return fd
    }

    /// Writes `data` over `name` in the open folder `dirfd`: `name` must be
    /// a regular file with one link (checked here, on the folder, right
    /// before the write); temp file made with O_EXCL | O_NOFOLLOW; ACL and
    /// extended attributes copied from the file (fcopyfile); exact mode;
    /// then renameat. The temp file is removed on any failure.
    ///
    /// renameat replaces a read-only file as long as its folder is
    /// writable, so the file's own write permission is checked again right
    /// before it (faccessat, not following a link): a file made read-only
    /// since the earlier checks throws `ReadOnly` and is left alone
    /// (release review 0.2.1 M2).
    static func replace(_ data: Data, name: String, in dirfd: Int32, mode: mode_t) throws {
        // One name, by the bytes openat and renameat get: a NUL would cut it
        // short and a slash before a combining mark would make it a path
        // (Astra batch 6 must-fix 1).
        guard Beneath.isName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        var st = stat()
        guard fstatat(dirfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let src = openat(dirfd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard src >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(src) }
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var tmp = ""
        var fd: Int32 = -1
        for _ in 0..<64 {
            tmp = "." + name + FileReplace.tempMarker + String((0..<6).map { _ in alphabet.randomElement()! })
            fd = openat(dirfd, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd >= 0 || errno != EEXIST { break }
        }
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var ok = data.withUnsafeBytes { buf -> Bool in
            var off = 0
            while off < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + off, buf.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        if ok { ok = fsync(fd) == 0 }
        if ok {
            // ACL and xattrs from the file being replaced (not COPYFILE_STAT:
            // that copies the old dates too); then the mode exactly.
            _ = fcopyfile(src, fd, nil, copyfile_flags_t(COPYFILE_ACL | COPYFILE_XATTR))
            ok = fchmod(fd, mode) == 0
        }
        close(fd)
        if ok, faccessat(dirfd, name, W_OK, AT_SYMLINK_NOFOLLOW) != 0 {
            unlinkat(dirfd, tmp, 0)
            throw ReadOnly()
        }
        guard ok, renameat(dirfd, tmp, dirfd, name) == 0 else {
            unlinkat(dirfd, tmp, 0)
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

// MARK: - Undo store

/// The originals of each Replace in Files operation, so Undo Replace in
/// Files can put them back: `<root>/<uuid>/` (owner-only, 0700) holds
/// `manifest.json` and one backup file per written file. Kept for the
/// last 5 operations or 7 days.
public final class ReplaceUndoStore: @unchecked Sendable {
    public let root: URL

    /// ~/Library/Application Support/Cedric/ReplaceUndo
    public static var defaultRoot: URL { PrivateDirectory.supportRoot.appendingPathComponent("ReplaceUndo", isDirectory: true) }

    public init(root: URL = ReplaceUndoStore.defaultRoot) { self.root = root }

    public struct Entry: Codable, Sendable, Equatable {
        public var path: String
        public var backup: String
        public var originalSHA256: String
        public var writtenSHA256: String
        public var mode: UInt16
        public var originalSize: Int
        public var writtenModified: Date?
        /// Saved once the writes are done: a crash before that leaves it
        /// false for files that were written, so undo decides from the
        /// bytes (SHA-256), not from this flag.
        public var written: Bool
        public var restored = false
        /// Not written (changed since the preview, or the write failed).
        /// Optional: manifests from before 0.2.0's review have no such key.
        public var dropped: Bool?
    }

    public struct Manifest: Codable, Sendable {
        public var id: UUID
        public var date: Date
        public var query: ReplaceQuery
        public var entries: [Entry]
        public var undone = false
        /// The searched folder: undo writes relative to it, links refused
        /// on the way (as the replace did). Optional: older manifests.
        public var root: String?
    }

    public final class Operation: @unchecked Sendable {
        public let id: UUID
        let dir: URL
        var manifest: Manifest

        init(dir: URL, manifest: Manifest) {
            self.dir = dir
            self.manifest = manifest
            id = manifest.id
        }

        func backup(_ original: Data, index: Int, for url: URL, written: Data, mode: mode_t) throws {
            let name = "\(index).orig"
            try PrivateDirectory.writePrivateFile(original, to: dir.appendingPathComponent(name))
            manifest.entries.append(Entry(path: url.standardizedFileURL.path, backup: name,
                                          originalSHA256: FileReplace.sha256(original).sha256Hex,
                                          writtenSHA256: FileReplace.sha256(written).sha256Hex, mode: UInt16(mode),
                                          originalSize: original.count, writtenModified: nil, written: false))
        }

        func noteWritten(index: Int, stamp: DiskStamp?) {
            manifest.entries[index].written = true
            manifest.entries[index].writtenModified = stamp?.modified
        }

        func drop(index: Int) {
            manifest.entries[index].written = false
            manifest.entries[index].dropped = true
        }

        func save() throws {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try PrivateDirectory.writePrivateFile(try enc.encode(manifest), to: dir.appendingPathComponent("manifest.json"))
        }
    }

    func begin(query: ReplaceQuery, root folder: URL? = nil, now: Date = Date()) throws -> Operation {
        let id = UUID()
        let dir = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try PrivateDirectory.make(dir, root: root)
        // The originals of replaced files: kept 7 days for Undo, not backed up.
        PrivateDirectory.excludeFromBackup(root)
        let op = Operation(dir: dir, manifest: Manifest(id: id, date: now, query: query, entries: [],
                                                        root: folder?.standardizedFileURL.path))
        try op.save()
        // After the new folder exists, so the 5 kept include it.
        prune(now: now, keeping: id)
        return op
    }

    public func manifest(_ id: UUID) -> Manifest? {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let d = try? Data(contentsOf: root.appendingPathComponent(id.uuidString).appendingPathComponent("manifest.json")) else { return nil }
        return try? dec.decode(Manifest.self, from: d)
    }

    public struct UndoReport: Sendable {
        public var restored: [URL] = []
        public var skipped: [SkippedFile] = []
        /// Files left to restore that a later undo may still put back
        /// (read-only now, the write failed, or the backup copy couldn't
        /// be read): the operation stays
        /// undoable. False when everything was decided.
        public var remaining = false
    }

    /// Puts back every backed-up file whose bytes are exactly what the
    /// replace wrote, decided from its SHA-256 (not the manifest's written
    /// flag, which a crash mid-replace never saved): a file still holding
    /// the original needs nothing; one changed since is skipped and
    /// reported, as is one now read-only or whose backup copy can't be
    /// read (both left to a later undo, with the reason). The
    /// operation is marked undone only when nothing is left to retry.
    /// Reads, hashes and writes files: call it off the main thread;
    /// `progress(done, total)` after each file.
    public func undo(_ id: UUID, progress: (Int, Int) -> Void = { _, _ in }) -> UndoReport {
        var report = UndoReport()
        guard var m = manifest(id), !m.undone else { return report }
        let dir = root.appendingPathComponent(id.uuidString)
        let todo = m.entries.indices.filter { !m.entries[$0].restored }
        for (n, k) in todo.enumerated() {
            defer { progress(n + 1, todo.count) }
            let e = m.entries[k]
            let url = URL(fileURLWithPath: e.path)
            func skip(_ r: ReplaceSkip) { report.skipped.append(SkippedFile(url: url, relativePath: url.lastPathComponent, reason: r)) }
            // Never written as far as the manifest knows, and not ours now: nothing to say.
            let quiet = e.dropped == true && !e.written
            var st = stat()
            guard lstat(e.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1,
                  let current = try? Data(contentsOf: url) else {
                if !quiet { skip(.changedSinceReplace) }
                m.entries[k].restored = true
                continue
            }
            let sha = FileReplace.sha256(current).sha256Hex
            if sha == e.originalSHA256 { m.entries[k].restored = true; continue }
            guard sha == e.writtenSHA256 else {
                if !quiet { skip(.changedSinceReplace) }
                m.entries[k].restored = true
                continue
            }
            if access(e.path, W_OK) != 0 { skip(.readOnly); report.remaining = true; continue }
            // The copy of the original: if it can't be read (moved, permissions,
            // a disk error) or isn't what was backed up, the file stays as the
            // replace left it, and so does the operation, for another try.
            let original: Data
            switch Self.readBackup(dir.appendingPathComponent(e.backup), sha256: e.originalSHA256) {
            case .success(let d): original = d
            case .failure(let why):
                report.skipped.append(SkippedFile(url: url, relativePath: url.lastPathComponent, reason: .backupUnreadable, detail: why.text))
                report.remaining = true
                continue
            }
            do {
                try FileReplace.atomicWrite(original, to: url, mode: st.st_mode & 0o7777,
                                            root: m.root.map { URL(fileURLWithPath: $0, isDirectory: true) })
                m.entries[k].restored = true
                report.restored.append(url)
            } catch {
                // Made read-only after the check above: the same report as there.
                skip(error is TreeWrite.ReadOnly ? .readOnly : .unwritable)
                report.remaining = true
            }
        }
        m.undone = !report.remaining
        let op = Operation(dir: dir, manifest: m)
        try? op.save()
        return report
    }

    struct BackupError: Error { var text: String }

    /// The backup copy at `url`, if it reads and matches `sha256`; or why not.
    static func readBackup(_ url: URL, sha256: String) -> Result<Data, BackupError> {
        let data: Data
        do { data = try Data(contentsOf: url) } catch {
            let ns = error as NSError
            let posix = (ns.userInfo[NSUnderlyingErrorKey] as? NSError).flatMap { $0.domain == NSPOSIXErrorDomain ? Int32($0.code) : nil }
            switch posix ?? (ns.code == NSFileReadNoSuchFileError ? ENOENT : ns.code == NSFileReadNoPermissionError ? EACCES : 0) {
            case ENOENT: return .failure(BackupError(text: String(localized: "missing")))
            case EACCES, EPERM: return .failure(BackupError(text: String(localized: "permission denied")))
            case 0: return .failure(BackupError(text: ns.localizedDescription))
            case let code: return .failure(BackupError(text: String(cString: strerror(code)).lowercased()))
            }
        }
        guard FileReplace.sha256(data).sha256Hex == sha256 else {
            return .failure(BackupError(text: String(localized: "doesn’t match the original")))
        }
        return .success(data)
    }

    /// At launch (the app runs it off the main thread, after the first
    /// frame): drops the copies past 7 days or past the newest 5, so they
    /// go even when no replace follows.
    public func pruneAtLaunch(now: Date = Date()) {
        prune(now: now)
    }

    /// Keeps the newest `keep` operations younger than `maxAge` (and
    /// always `keeping`, the operation being made).
    public func prune(keep: Int = 5, maxAge: TimeInterval = 7 * 24 * 3600, now: Date = Date(), keeping: UUID? = nil) {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        var ops: [(URL, Date)] = []
        for d in dirs {
            guard let id = UUID(uuidString: d.lastPathComponent) else { continue }
            let date = manifest(id)?.date ?? ((try? fm.attributesOfItem(atPath: d.path)[.modificationDate]) as? Date) ?? .distantPast
            ops.append((d, date))
        }
        ops.sort { $0.1 > $1.1 }
        for (k, (d, date)) in ops.enumerated() where k >= keep || now.timeIntervalSince(date) > maxAge {
            if let keeping, d.lastPathComponent == keeping.uuidString { continue }
            try? fm.removeItem(at: d)
        }
    }
}

extension Data {
    var sha256Hex: String { map { String(format: "%02x", $0) }.joined() }
}
