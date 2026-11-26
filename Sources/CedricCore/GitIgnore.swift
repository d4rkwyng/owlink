import Foundation

/// .gitignore matching without a git process (Find in Files, Replace in
/// Files; later the folder sidebar). Follows gitignore(5):
///
/// - blank lines and `#` comments are skipped; `\#` and `\!` are literal;
/// - trailing spaces are dropped unless escaped (`\ `);
/// - `!` re-includes what an earlier pattern excluded, but never a path
///   whose parent folder is excluded (git doesn't descend there);
/// - a trailing `/` matches folders only;
/// - a `/` at the start or in the middle anchors the pattern to the
///   .gitignore's own folder, otherwise it matches a name at any depth;
/// - `*`, `?`, `[...]` (`[!...]`, ranges) never match `/`; `**/`, `/**/`
///   and `/**` match any number of folders;
/// - deeper .gitignore files override shallower ones; within a file the
///   last matching line wins; `.git/info/exclude` comes below them all.
///
/// Not read: `core.excludesFile` (needs git config) and `core.ignoreCase`
/// (matching is case-sensitive, git's default on Linux).
public struct GitIgnoreRules: Sendable, Equatable {
    public struct Pattern: Sendable, Equatable {
        public var glob: String
        public var negated: Bool
        public var dirOnly: Bool
        /// Matched against the path relative to the rules' folder; else
        /// against the last path component.
        public var anchored: Bool
    }

    public var patterns: [Pattern]

    public init(_ text: String) {
        patterns = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" || $0 == "\r" })
            .compactMap { Self.parse(String($0)) }
    }

    static func parse(_ raw: String) -> Pattern? {
        var line = Array(raw)
        if line.last == "\r" { line.removeLast() }
        // Trailing spaces, unless the last one is escaped.
        while line.last == " " {
            var backslashes = 0
            var k = line.count - 2
            while k >= 0, line[k] == "\\" { backslashes += 1; k -= 1 }
            if backslashes % 2 == 1 { break }
            line.removeLast()
        }
        guard !line.isEmpty, line[0] != "#" else { return nil }
        var negated = false
        if line[0] == "!" { negated = true; line.removeFirst() }
        else if line.count >= 2, line[0] == "\\", line[1] == "#" || line[1] == "!" { line.removeFirst() }
        // The slashes by their bytes: a "/" before a combining mark is one
        // Swift character with it, but still anchors the pattern.
        var bytes = Array(String(line).utf8)
        var dirOnly = false
        if bytes.last == 0x2f { dirOnly = true; while bytes.last == 0x2f { bytes.removeLast() } }
        guard !bytes.isEmpty else { return nil }
        let anchored = bytes.contains(0x2f)
        if bytes.first == 0x2f { bytes.removeFirst() }
        guard !bytes.isEmpty else { return nil }
        return Pattern(glob: String(decoding: bytes, as: UTF8.self), negated: negated, dirOnly: dirOnly, anchored: anchored)
    }

    /// The last pattern matching `path` (relative to the rules' folder, no
    /// leading "/"): true ignored, false re-included, nil no opinion.
    public func decision(_ path: String, isDirectory: Bool) -> Bool? {
        let name = FolderTree.components(path).last ?? path
        for p in patterns.reversed() {
            if p.dirOnly && !isDirectory { continue }
            if GitIgnore.wildmatch(p.glob, p.anchored ? path : name) { return !p.negated }
        }
        return nil
    }
}

/// The ignore rules of one tree: the repository's `.git/info/exclude`
/// and every `.gitignore` from the repository root down, each read lazily
/// the first time a path below it is asked about. Not thread-safe: one
/// walker uses one instance.
public final class GitIgnore {
    /// The repository root (the folder holding `.git`), or the searched
    /// folder when it isn't in a repository: its .gitignore files still
    /// apply (a copy of a repo without its .git).
    public let root: URL
    private let exclude: GitIgnoreRules?
    // By the relative folder's bytes (`FolderTree.PathKey`): a `String`
    // key gave a canonically equivalent folder (the Ohm sign for Omega)
    // the other's rules and answer, where git matches bytes.
    private var rules: FolderTree.PathMap<GitIgnoreRules?> = [:]
    private var ignoredDirs: FolderTree.PathMap<Bool> = [:]

    /// `folder`: where the walk starts (symbolic links resolved).
    public init(folder: URL) {
        let start = folder.standardizedFileURL.resolvingSymlinksInPath()
        var repo: URL?
        // Walked by path, not URL: on macOS 15 the URL parent of "/" is
        // "/..", then "/../..", so a URL walk that stops when the parent
        // equals the child never ends outside a git repo (0.2.0 VM test).
        var path = start.path
        while true {
            if FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git")) {
                repo = URL(fileURLWithPath: path, isDirectory: true)
                break
            }
            let parent = (path as NSString).deletingLastPathComponent
            if path == "/" || parent.isEmpty || parent.count >= path.count { break }
            path = parent
        }
        root = repo ?? start
        if let repo, let gitDir = Self.gitDirectory(repo),
           let text = try? String(contentsOf: gitDir.appendingPathComponent("info/exclude"), encoding: .utf8) {
            exclude = GitIgnoreRules(text)
        } else {
            exclude = nil
        }
    }

    /// `.git` itself, or for a worktree/submodule (`.git` is a file with
    /// "gitdir: …") the common git folder its info/exclude lives in.
    static func gitDirectory(_ repo: URL) -> URL? {
        let dotGit = repo.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) else { return nil }
        if isDir.boolValue { return dotGit }
        guard let s = try? String(contentsOf: dotGit, encoding: .utf8), s.hasPrefix("gitdir:") else { return nil }
        let p = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
        // Absolute by the first byte, as git and the kernel read it.
        var dir = p.utf8.first == 0x2f ? URL(fileURLWithPath: p) : repo.appendingPathComponent(p)
        if let common = try? String(contentsOf: dir.appendingPathComponent("commondir"), encoding: .utf8) {
            let c = common.trimmingCharacters(in: .whitespacesAndNewlines)
            dir = c.utf8.first == 0x2f ? URL(fileURLWithPath: c) : dir.appendingPathComponent(c)
        }
        return dir.standardizedFileURL
    }

    /// Whether `url` (symbolic links resolved by the caller) is ignored.
    /// Paths outside `root`, and `root` itself, never are. Placed by the
    /// path bytes (FolderTree.relativePath): a text prefix test fused
    /// "root/" with a name starting with a combining mark.
    public func isIgnored(_ url: URL, isDirectory: Bool) -> Bool {
        guard let rel = FolderTree.relativePath(of: url, in: root), !rel.isEmpty else { return false }
        return isIgnored(relative: rel, isDirectory: isDirectory)
    }

    /// `rel`: relative to `root`, "/"-separated, split at the "/" bytes
    /// (FolderTree.components): a text split fused a folder with a child
    /// whose name starts with a combining mark, and skipped the folder's
    /// own .gitignore.
    public func isIgnored(relative rel: String, isDirectory: Bool) -> Bool {
        let comps = FolderTree.components(rel)
        guard !comps.isEmpty else { return false }
        // A path in an ignored folder is ignored, whatever its own rules say.
        var prefix = ""
        for c in comps.dropLast() {
            prefix = prefix.isEmpty ? c : prefix + "/" + c
            if dirIgnored(prefix) { return true }
        }
        return ownDecision(comps, isDirectory: isDirectory)
    }

    private func dirIgnored(_ rel: String) -> Bool {
        if let d = ignoredDirs[rel] { return d }
        let comps = FolderTree.components(rel)
        var parentIgnored = false
        if comps.count > 1 { parentIgnored = dirIgnored(comps.dropLast().joined(separator: "/")) }
        let d = parentIgnored || ownDecision(comps, isDirectory: true)
        ignoredDirs[rel] = d
        return d
    }

    /// The deepest .gitignore with an opinion wins; then info/exclude.
    private func ownDecision(_ comps: [String], isDirectory: Bool) -> Bool {
        var k = comps.count - 1
        while k >= 0 {
            let base = comps[0..<k].joined(separator: "/")
            if let r = rulesFor(base) {
                let sub = comps[k...].joined(separator: "/")
                if let d = r.decision(sub, isDirectory: isDirectory) { return d }
            }
            k -= 1
        }
        return exclude?.decision(comps.joined(separator: "/"), isDirectory: isDirectory) ?? false
    }

    private func rulesFor(_ dirRel: String) -> GitIgnoreRules? {
        if let r = rules[dirRel] { return r }
        let file = dirRel.isEmpty ? root.appendingPathComponent(".gitignore") : root.appendingPathComponent(dirRel).appendingPathComponent(".gitignore")
        var r: GitIgnoreRules?
        if let data = try? Data(contentsOf: file), data.count < 1_048_576 {
            let text = String(decoding: data, as: UTF8.self)
            let parsed = GitIgnoreRules(text)
            r = parsed.patterns.isEmpty ? nil : parsed
        }
        rules[dirRel] = .some(r)
        return r
    }

    // MARK: wildmatch

    /// git's wildmatch with WM_PATHNAME: `*` and `?` stop at "/", `**`
    /// between slashes (or at either end) spans folders.
    public static func wildmatch(_ pattern: String, _ s: String) -> Bool {
        let p = Array(pattern.unicodeScalars), t = Array(s.unicodeScalars)
        var budget = 100_000
        return match(p, 0, t, 0, &budget)
    }

    private static func match(_ p: [Unicode.Scalar], _ pi0: Int, _ t: [Unicode.Scalar], _ ti0: Int, _ budget: inout Int) -> Bool {
        var pi = pi0, ti = ti0
        budget -= 1
        if budget < 0 { return false }
        while pi < p.count {
            let c = p[pi]
            switch c {
            case "*":
                var q = pi
                while q < p.count, p[q] == "*" { q += 1 }
                let double = q - pi >= 2
                if double, pi == 0 || p[pi - 1] == "/", q == p.count || p[q] == "/" {
                    if q == p.count { return true }
                    // "**/": zero folders, or any run ending at a "/".
                    if match(p, q + 1, t, ti, &budget) { return true }
                    var k = ti
                    while k < t.count {
                        if t[k] == "/", match(p, q + 1, t, k + 1, &budget) { return true }
                        k += 1
                    }
                    return false
                }
                // A single star (or ** not between slashes): no "/".
                var k = ti
                while true {
                    if match(p, q, t, k, &budget) { return true }
                    if k >= t.count || t[k] == "/" { return false }
                    k += 1
                }
            case "?":
                guard ti < t.count, t[ti] != "/" else { return false }
                pi += 1; ti += 1
            case "[":
                guard ti < t.count, t[ti] != "/" else { return false }
                guard let (ok, next) = bracket(p, pi, t[ti]) else {
                    // An unclosed "[" is a literal.
                    guard t[ti] == "[" else { return false }
                    pi += 1; ti += 1
                    continue
                }
                guard ok else { return false }
                pi = next; ti += 1
            case "\\" where pi + 1 < p.count:
                guard ti < t.count, t[ti] == p[pi + 1] else { return false }
                pi += 2; ti += 1
            default:
                guard ti < t.count, t[ti] == c else { return false }
                pi += 1; ti += 1
            }
        }
        return ti == t.count
    }

    /// A `[...]` class at `p[start]`: whether `ch` is in it and the index
    /// after the closing "]"; nil if it never closes.
    private static func bracket(_ p: [Unicode.Scalar], _ start: Int, _ ch: Unicode.Scalar) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count, p[i] == "!" || p[i] == "^" { negate = true; i += 1 }
        var hit = false
        var first = true
        while i < p.count {
            var lo = p[i]
            if lo == "]", !first { return (hit != negate, i + 1) }
            first = false
            if lo == "\\", i + 1 < p.count { i += 1; lo = p[i] }
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                var hi = p[i + 2]
                var adv = 3
                if hi == "\\", i + 3 < p.count { hi = p[i + 3]; adv = 4 }
                if lo.value <= ch.value, ch.value <= hi.value { hit = true }
                i += adv
            } else {
                if lo == ch { hit = true }
                i += 1
            }
        }
        return nil
    }
}
