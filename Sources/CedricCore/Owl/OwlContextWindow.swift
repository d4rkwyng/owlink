import Foundation

/// Builds the `OwlContext` a provider sees: the visible lines plus about 40
/// lines either side, whole lines only, capped at 8 KB (8,192 UTF-16 code
/// units). A document that fits in the cap is sent whole.
///
/// Coordinates: in an `OwlContext` built here, `visibleRange`, `selection`
/// and every `OwlHint.range` a provider returns are UTF-16 offsets into
/// `context.text`, not into the document. `context.textStart` (= `offset`)
/// is where that text starts in the document. The coordinator converts a
/// hint's range to `range.location + textStart`, drops the hint if that
/// range is out of bounds or the document's edit generation moved, and
/// Apply also checks the text there is still what the provider saw. The
/// rules provider follows the same convention: its ranges are relative to
/// `context.text` too (they equal document ranges only when textStart = 0).
public struct OwlContextWindow: Sendable {
    public static let byteCap = 8192
    public static let marginLines = 40

    public let context: OwlContext
    /// Where `context.text` starts in the document (= `context.textStart`).
    public let offset: Int
    /// The whole document is in `context.text`.
    public let isWholeDocument: Bool

    public init(text full: NSString, visible: NSRange, selection: NSRange?, fileName: String?, language: String,
                documentID: UUID, editGeneration: Int, cap: Int = OwlContextWindow.byteCap, margin: Int = OwlContextWindow.marginLines) {
        let length = full.length
        var range: NSRange
        if length <= cap {
            range = NSRange(location: 0, length: length)
        } else {
            let vis = NSIntersectionRange(visible, NSRange(location: 0, length: length))
            var start = full.lineRange(for: NSRange(location: vis.location, length: 0)).location
            var end = NSMaxRange(full.lineRange(for: NSRange(location: max(vis.location, NSMaxRange(vis) - (vis.length > 0 ? 1 : 0)), length: 0)))
            for _ in 0..<margin {
                if start > 0 { start = full.lineRange(for: NSRange(location: start - 1, length: 0)).location }
                if end < length { end = NSMaxRange(full.lineRange(for: NSRange(location: end, length: 0))) }
            }
            // Over the cap: drop margin lines from the larger side.
            while end - start > cap {
                let top = vis.location - start, bottom = end - NSMaxRange(vis)
                if top <= 0 && bottom <= 0 { end = start + cap; break }
                if top >= bottom {
                    start = min(NSMaxRange(full.lineRange(for: NSRange(location: start, length: 0))), vis.location)
                } else {
                    end = max(full.lineRange(for: NSRange(location: end - 1, length: 0)).location, NSMaxRange(vis))
                }
            }
            range = NSRange(location: start, length: end - start)
        }
        // Never split a surrogate pair at the cap.
        if NSMaxRange(range) < length, range.length > 0,
           CFStringIsSurrogateHighCharacter(full.character(at: NSMaxRange(range) - 1)) {
            range.length -= 1
        }
        func local(_ r: NSRange) -> NSRange {
            let s = min(max(r.location - range.location, 0), range.length)
            let e = min(max(NSMaxRange(r) - range.location, 0), range.length)
            return NSRange(location: s, length: e - s)
        }
        offset = range.location
        isWholeDocument = range.location == 0 && range.length == length
        context = OwlContext(fileName: fileName, language: language, text: full.substring(with: range), textStart: range.location,
                             visibleRange: local(visible), selection: selection.map(local),
                             documentID: documentID, editGeneration: editGeneration, isWholeDocument: isWholeDocument)
    }
}

/// What the app knows about a document beyond its text, for the rules that
/// need it (reload, unsaved for hours, CRLF).
public struct OwlDocumentFacts: Sendable, Equatable {
    public var isWholeDocument: Bool
    public var changedOnDisk: Bool
    /// When the document last went from saved to unsaved (nil: saved).
    public var unsavedSince: Date?
    public var lineEnding: LineEnding
    /// The file had more than one kind of line ending when it was read.
    public var mixedLineEndings: Bool
    /// The language was picked from the menu: the owl doesn't second-guess it.
    public var languageIsManual: Bool
    /// The time rules that depend on it (certificate expiry) use; nil: now.
    public var now: Date?
    /// Settings › "Style tips in code": the style rules run too. Off by
    /// default; the correctness rules always run.
    public var styleTips: Bool
    /// Whether a path relative to the document's folder exists (Markdown's
    /// relative links). Nil: the document has no folder (untitled) and the
    /// rule is skipped. The probe answers nil while it doesn't know yet:
    /// the app checks off the main thread and the next query has the answer.
    public var fileExists: OwlFileProbe?
    /// A script that came from the internet (it has the
    /// com.apple.quarantine attribute) and hasn't had the offer to check it
    /// yet: the owl offers Check Script for Risks, once per file.
    public var isQuarantined: Bool
    /// The `.editorconfig` values for this file (nil: none, or not read
    /// yet). The whitespace rules follow them: `false` turns the matching
    /// rule off, and indent_style picks the side mixed indentation goes to.
    public var editorConfig: EditorConfig.Values?
    /// Settings › Style Check (filler words, redundancies, clichés in
    /// prose): its language, extra phrases and exceptions. nil: off (the
    /// default).
    public var styleCheck: StyleCheck.Settings?

    public init(isWholeDocument: Bool = true, changedOnDisk: Bool = false, unsavedSince: Date? = nil, lineEnding: LineEnding = .lf,
                mixedLineEndings: Bool = false, languageIsManual: Bool = false, now: Date? = nil, styleTips: Bool = false,
                fileExists: OwlFileProbe? = nil, isQuarantined: Bool = false, editorConfig: EditorConfig.Values? = nil,
                styleCheck: StyleCheck.Settings? = nil) {
        self.styleCheck = styleCheck
        self.editorConfig = editorConfig
        self.fileExists = fileExists
        self.isQuarantined = isQuarantined
        self.now = now
        self.styleTips = styleTips
        self.isWholeDocument = isWholeDocument
        self.changedOnDisk = changedOnDisk
        self.unsavedSince = unsavedSince
        self.lineEnding = lineEnding
        self.mixedLineEndings = mixedLineEndings
        self.languageIsManual = languageIsManual
    }
}

/// Answers "does this relative path exist?" for the rules (see
/// `OwlDocumentFacts.fileExists`): true, false, or nil for not known yet.
/// Two probes are equal when they are the same probe (`id`).
public struct OwlFileProbe: Sendable, Equatable {
    public let id: UUID
    public let exists: @Sendable (String) -> Bool?
    /// The Markdown and image files under the document's folder, as paths
    /// relative to it (at most `OwlFileProbe.scanLimit` entries looked at),
    /// for a broken link's nearest-file Fix it. It answers nil while it
    /// doesn't know yet (the app lists the folder off the main thread and
    /// the next query has it); no closure: no list, no nearest-file fix.
    public let files: (@Sendable () -> [String]?)?

    public init(id: UUID = UUID(), exists: @escaping @Sendable (String) -> Bool?, files: (@Sendable () -> [String]?)? = nil) {
        self.id = id
        self.exists = exists
        self.files = files
    }

    /// How many folder entries the app's scan looks at, at most.
    public static let scanLimit = 2000
    /// How deep below the document's folder it looks.
    public static let scanDepth = 6
    /// The files a nearest-file match can be: Markdown and images.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdx", "mdown", "mkd"]
    public static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "avif", "heic", "tif", "tiff", "bmp", "ico", "pdf"]

    /// Lists the Markdown and image files under `folder` (relative paths),
    /// skipping hidden files, packages and installed copies, looking at no
    /// more than `scanLimit` entries. Disk I/O: call it off the main thread.
    public static func scan(folder: URL) -> [String] {
        let base = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var out: [String] = [], seen = 0
        for case let url as URL in walker {
            seen += 1
            if seen > scanLimit { break }
            let name = url.lastPathComponent
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                if installedCopyFolders.contains(name) || walker.level >= scanDepth { walker.skipDescendants() }
                continue
            }
            let ext = (name as NSString).pathExtension.lowercased()
            guard markdownExtensions.contains(ext) || imageExtensions.contains(ext) else { continue }
            // Its place under `base` by the path bytes (FolderTree.relativePath):
            // a text prefix test fused "base/" with a folder name starting
            // with a combining mark and dropped its files. As enumerated;
            // only if that's missing or empty, resolved (resolving every
            // entry costs a symlink walk per file).
            var rel = FolderTree.relativePath(of: url, in: base)
            if rel?.isEmpty ?? true { rel = FolderTree.relativePath(of: url.resolvingSymlinksInPath(), in: base) }
            if let rel, !rel.isEmpty { out.append(rel) }
        }
        return out
    }

    /// Folders whose Markdown is an installed or vendored copy of a
    /// package (node_modules, PlatformIO libraries, site-packages…): the
    /// files its links point to were left out on purpose. No probe there.
    public static let installedCopyFolders: Set<String> = ["node_modules", "libdeps", "site-packages", "dist-packages", "vendor", "Pods",
                                                           "Carthage", ".build", "DerivedData", "bower_components", "jspm_packages", ".venv", "venv"]

    public static func probes(folder: URL) -> Bool {
        !folder.pathComponents.contains(where: installedCopyFolders.contains)
    }

    /// A fixed set of existing paths (tests).
    public static func set(_ paths: Set<String>) -> OwlFileProbe {
        OwlFileProbe(exists: { p in paths.contains((p as NSString).standardizingPath) || paths.contains(p) },
                     files: { paths.filter { !$0.hasPrefix("..") && !$0.hasSuffix("/") }.sorted() })
    }

    public static func == (a: OwlFileProbe, b: OwlFileProbe) -> Bool { a.id == b.id }
}

/// A provider that also wants the document facts. The coordinator calls
/// this instead of `hints(for:)` when a provider adopts it.
public protocol OwlFactsAwareProvider: OwlHintProvider {
    func hints(for context: OwlContext, facts: OwlDocumentFacts) async -> [OwlHint]
}

/// Turns a replacement of `range` in `old` into the smallest equivalent
/// edit (common prefix and suffix dropped), so applying a hint moves as
/// little text, and as little of the selection, as possible.
public enum OwlEdit {
    public static func minimal(in old: NSString, range: NSRange, replacement: String) -> (range: NSRange, replacement: String) {
        let a = old.substring(with: range) as NSString
        let b = replacement as NSString
        var p = 0
        let maxP = min(a.length, b.length)
        while p < maxP, a.character(at: p) == b.character(at: p) { p += 1 }
        var s = 0
        while s < maxP - p, a.character(at: a.length - 1 - s) == b.character(at: b.length - 1 - s) { s += 1 }
        // Keep surrogate pairs whole.
        if p > 0, CFStringIsSurrogateHighCharacter(a.character(at: p - 1)) { p -= 1 }
        if s > 0, CFStringIsSurrogateLowCharacter(a.character(at: a.length - s)) { s -= 1 }
        let r = NSRange(location: range.location + p, length: a.length - p - s)
        return (r, b.substring(with: NSRange(location: p, length: b.length - p - s)))
    }
}
