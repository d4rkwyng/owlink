import Foundation

/// Find in Files: walks a folder, skips excluded paths, binaries and big
/// files, and reports every matching line. Runs off the main thread,
/// streams results in batches and can be cancelled.
public struct FileSearchOptions: Sendable {
    public var root: URL
    public var query: String
    public var regex: Bool
    public var caseSensitive: Bool
    /// File-name globs to search ("*.swift"); empty means every file. A
    /// glob with a "/" is matched against the path relative to `root`.
    public var include: [String]
    /// Globs for files or folders to skip, matched against each path
    /// component's name (and the relative path if the glob has a "/").
    public var exclude: [String]
    public var maxResults: Int
    public var maxFileSize: Int
    /// Skip what the tree's .gitignore files (and .git/info/exclude) ignore.
    public var respectGitIgnore: Bool

    public static let defaultExclude = [".git", "node_modules", "build", "dist"]

    public init(root: URL, query: String, regex: Bool = false, caseSensitive: Bool = false,
                include: [String] = [], exclude: [String] = FileSearchOptions.defaultExclude,
                maxResults: Int = 10_000, maxFileSize: Int = 20 * 1024 * 1024, respectGitIgnore: Bool = false) {
        self.root = root
        self.query = query
        self.regex = regex
        self.caseSensitive = caseSensitive
        self.include = include
        self.exclude = exclude
        self.maxResults = maxResults
        self.maxFileSize = maxFileSize
        self.respectGitIgnore = respectGitIgnore
    }

    /// "*.swift, *.md;*.txt" → ["*.swift", "*.md", "*.txt"].
    public static func globs(_ s: String) -> [String] {
        s.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }
}

public struct FileSearchResult: Sendable, Equatable {
    public var url: URL
    public var relativePath: String
    /// 1-based.
    public var line: Int
    /// 1-based, in UTF-16 units, of the first match on the line.
    public var column: Int
    /// The line, cut to 400 characters around the first match.
    public var text: String
    /// The matches within `text`.
    public var ranges: [NSRange]
    /// Every match on the line, in UTF-16 offsets into the whole decoded
    /// file (line endings normalised to LF, BOM dropped).
    public var matchRanges: [NSRange] = []
    /// The file's modification date and size when it was searched.
    public var stamp: DiskStamp?

    public init(url: URL, relativePath: String, line: Int, column: Int, text: String, ranges: [NSRange],
                matchRanges: [NSRange] = [], stamp: DiskStamp? = nil) {
        self.url = url
        self.relativePath = relativePath
        self.line = line
        self.column = column
        self.text = text
        self.ranges = ranges
        self.matchRanges = matchRanges
        self.stamp = stamp
    }
}

public struct FileSearchSummary: Sendable, Equatable {
    public var filesSearched = 0
    public var filesMatched = 0
    public var results = 0
    public var skippedBinary = 0
    public var skippedLarge = 0
    /// The files counted in `skippedBinary` and `skippedLarge`, each with
    /// its reason (.binary or .tooLarge), in path order.
    public var skippedFiles: [SkippedFile] = []
    public var truncated = false
    public var cancelled = false
}

public final class FileSearch: @unchecked Sendable {
    public let options: FileSearchOptions
    private let lock = NSLock()
    private var _cancelled = false

    public init(_ options: FileSearchOptions) { self.options = options }

    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
    public func cancel() { lock.lock(); _cancelled = true; lock.unlock() }

    /// Starts on a background queue. `batch` and `done` are called on
    /// `callbackQueue` (results arrive in batches, at most every ~50 ms).
    public func start(callbackQueue: DispatchQueue = .main,
                      batch: @escaping @Sendable ([FileSearchResult]) -> Void,
                      done: @escaping @Sendable (Result<FileSearchSummary, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var pending: [FileSearchResult] = []
            var last = Date()
            do {
                let summary = try run { r in
                    pending.append(r)
                    if pending.count >= 200 || Date().timeIntervalSince(last) > 0.05 {
                        let b = pending
                        pending = []
                        last = Date()
                        callbackQueue.async { batch(b) }
                    }
                }
                let b = pending
                callbackQueue.async {
                    if !b.isEmpty { batch(b) }
                    done(.success(summary))
                }
            } catch {
                callbackQueue.async { done(.failure(error)) }
            }
        }
    }

    /// Searches synchronously on the calling thread.
    public func run(_ found: (FileSearchResult) -> Void) throws -> FileSearchSummary {
        let re = try FindEngine.regex(options.query, FindOptions(regex: options.regex, caseSensitive: options.caseSensitive))
        var summary = FileSearchSummary()
        let root = options.root.standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let ignore = options.respectGitIgnore ? GitIgnore(folder: root) : nil
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [],
                                                          errorHandler: { _, _ in true }) else { return summary }
        // Collect first and sort, so results come in a stable order (the
        // enumerator's order is the file system's).
        var files: [(URL, String, Int, Date?)] = []
        while let obj = walker.nextObject() {
            if isCancelled { summary.cancelled = true; return summary }
            guard let url = obj as? URL else { continue }
            let path = url.resolvingSymlinksInPath().path
            let rel = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            if isExcluded(rel) || ignore?.isIgnored(URL(fileURLWithPath: path), isDirectory: v.isDirectory == true) == true {
                if v.isDirectory == true { walker.skipDescendants() }
                continue
            }
            guard v.isRegularFile == true, v.isSymbolicLink != true else { continue }
            guard isIncluded(rel) else { continue }
            files.append((url, rel, v.fileSize ?? 0, v.contentModificationDate))
        }
        files.sort { $0.1.localizedStandardCompare($1.1) == .orderedAscending }

        for (url, rel, size, modified) in files {
            if isCancelled { summary.cancelled = true; break }
            func skip(_ reason: ReplaceSkip) {
                if reason == .tooLarge { summary.skippedLarge += 1 } else { summary.skippedBinary += 1 }
                summary.skippedFiles.append(SkippedFile(url: url, relativePath: rel, reason: reason))
            }
            if size > options.maxFileSize { skip(.tooLarge); continue }
            // Bytes of its own, not mapped: a file rewritten in place while
            // it's decoded gave text and line endings from other bytes. And
            // a regular file still: one swapped for a FIFO since the walk
            // blocked the search for good.
            TextCodec.beforeReadForTesting?(url)
            guard let data = try? TextCodec.snapshot(of: url) else { continue }
            TextCodec.afterReadForTesting?(url)
            if Self.looksBinary(data) { skip(.binary); continue }
            guard let decoded = TextCodec.decode(data) else { skip(.binary); continue }
            summary.filesSearched += 1
            let text = decoded.text as NSString
            var index: LineIndex?
            var lastLine = -1
            var fileHit = false
            var stop = false
            re.enumerateMatches(in: decoded.text, range: NSRange(location: 0, length: text.length)) { m, _, flag in
                guard let r = m?.range, r.length > 0 else { return }
                if index == nil { index = LineIndex(text) }
                let line = index!.line(containing: r.location)
                let content = index!.contentRange(ofLine: line)
                // One result per line; it carries every match on the line.
                if line == lastLine { return }
                lastLine = line
                fileHit = true
                // All matches on this line, relative to the line.
                var ranges: [NSRange] = []
                var fileRanges: [NSRange] = []
                re.enumerateMatches(in: decoded.text, range: content) { mm, _, _ in
                    if let rr = mm?.range, rr.length > 0 {
                        fileRanges.append(rr)
                        ranges.append(NSRange(location: rr.location - content.location, length: rr.length))
                    }
                }
                var lineText = text.substring(with: content)
                var shift = 0
                let lineLen = (lineText as NSString).length
                if lineLen > 400 {
                    let first = ranges.first?.location ?? 0
                    shift = max(0, min(first - 100, lineLen - 400))
                    lineText = (lineText as NSString).substring(with: NSRange(location: shift, length: 400))
                    ranges = ranges.compactMap {
                        let loc = $0.location - shift
                        return loc >= 0 && loc + $0.length <= 400 ? NSRange(location: loc, length: $0.length) : nil
                    }
                }
                found(FileSearchResult(url: url, relativePath: rel, line: line + 1, column: r.location - content.location + 1,
                                       text: lineText, ranges: ranges, matchRanges: fileRanges,
                                       stamp: DiskStamp(modified: modified, size: size)))
                summary.results += 1
                if summary.results >= self.options.maxResults { summary.truncated = true; stop = true; flag.pointee = true }
                if summary.results % 256 == 0, self.isCancelled { stop = true; flag.pointee = true }
            }
            if fileHit { summary.filesMatched += 1 }
            if stop {
                if isCancelled { summary.cancelled = true }
                break
            }
        }
        return summary
    }

    /// A NUL byte in the first 8 KB (UTF-16 files with a BOM excepted).
    public static func looksBinary(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) { return false }
        return head.contains(0)
    }

    func isExcluded(_ rel: String) -> Bool {
        let comps = rel.split(separator: "/")
        for g in options.exclude {
            if g.contains("/") {
                if Self.glob(g, rel) { return true }
            } else if comps.contains(where: { Self.glob(g, String($0)) }) {
                return true
            }
        }
        return false
    }

    func isIncluded(_ rel: String) -> Bool {
        guard !options.include.isEmpty else { return true }
        let name = (rel as NSString).lastPathComponent
        return options.include.contains { g in g.contains("/") ? Self.glob(g, rel) : Self.glob(g, name) }
    }

    /// Shell-style glob (`*`, `?`, `[...]`), via fnmatch(3). `**/` in a
    /// path glob matches any number of folders.
    public static func glob(_ pattern: String, _ s: String) -> Bool {
        if pattern.hasPrefix("**/") {
            let rest = String(pattern.dropFirst(3))
            if glob(rest, s) { return true }
            var parts = s.split(separator: "/")
            while parts.count > 1 {
                parts.removeFirst()
                if glob(rest, parts.joined(separator: "/")) { return true }
            }
            return false
        }
        return fnmatch(pattern, s, 0) == 0
    }
}
