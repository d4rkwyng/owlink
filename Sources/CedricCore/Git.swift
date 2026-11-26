import Foundation

// Git and GitHub, lightweight: where a file's repository is, what the
// status bar shows, the gutter's change marks and GitHub links. No
// network, no sign-in, no GitHub API: git runs locally and links are
// built from `remote.origin.url`.

/// Where a work tree and its git directory are.
public struct GitLocation: Equatable, Sendable {
    /// The work tree's root (the folder holding `.git`).
    public var workTree: URL
    /// The git directory holding this work tree's HEAD and index: `.git`
    /// itself, or for a linked work tree (`git worktree add`) or a
    /// submodule, the folder its `.git` file points to.
    public var gitDir: URL

    public init(workTree: URL, gitDir: URL) { self.workTree = workTree; self.gitDir = gitDir }

    /// Walks up from `file`'s folder to the nearest `.git` (a folder, or a
    /// `gitdir: …` file). File-system lookups only: no git process.
    public static func find(for file: URL, fileManager fm: FileManager = .default) -> GitLocation? {
        var dir = file.standardizedFileURL.deletingLastPathComponent()
        while true {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    // A real git directory has HEAD (an empty `.git` folder isn't one).
                    if fm.fileExists(atPath: dotGit.appendingPathComponent("HEAD").path) {
                        return GitLocation(workTree: dir, gitDir: dotGit)
                    }
                } else if let s = try? String(contentsOf: dotGit, encoding: .utf8), let gd = gitDirFromFile(s, relativeTo: dir) {
                    return GitLocation(workTree: dir, gitDir: gd)
                }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { return nil }
            dir = parent
        }
    }

    /// The target of a `.git` file: `gitdir: <path>`, relative to the
    /// folder holding the file unless absolute.
    public static func gitDirFromFile(_ contents: String, relativeTo dir: URL) -> URL? {
        guard let line = contents.split(whereSeparator: \.isNewline).first, line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        // Absolute by the first byte, as git and the kernel read it.
        return path.utf8.first == 0x2f ? URL(fileURLWithPath: path).standardizedFileURL
            : dir.appendingPathComponent(path).standardizedFileURL
    }
}

/// HEAD as `.git/HEAD` says it: a branch, or a detached commit.
public enum GitHead: Equatable, Sendable {
    case branch(String)
    case detached(String)

    public static func parse(_ contents: String) -> GitHead? {
        let s = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("ref:") {
            let ref = s.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return .branch(ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref)
        }
        guard s.count >= 7, s.allSatisfy(\.isHexDigit) else { return nil }
        return .detached(s)
    }
}

/// One file's state from `git status --porcelain=v2 --branch -z -- file`.
public struct GitFileStatus: Equatable, Sendable {
    /// The commit HEAD points at; nil before the first commit.
    public var headSHA: String?
    /// The branch name; nil when HEAD is detached.
    public var branch: String?
    /// The branch's upstream (`origin/main`), if it has one.
    public var upstream: String?
    /// The file differs from HEAD (staged or not), or is untracked.
    public var changed = false
    /// The file isn't in git at all (`??`).
    public var untracked = false
    /// Ignored by .gitignore (only reported with --ignored).
    public var ignored = false

    public init(headSHA: String? = nil, branch: String? = nil, upstream: String? = nil) {
        self.headSHA = headSHA; self.branch = branch; self.upstream = upstream
    }

    /// The status bar's label: the branch, or the short SHA when detached.
    public var label: String? {
        if let branch { return branch }
        if let headSHA { return String(headSHA.prefix(7)) }
        return nil
    }

    /// Parses NUL-separated porcelain v2 output with `--branch`.
    public static func parse(porcelainV2 output: String) -> GitFileStatus {
        var s = GitFileStatus()
        let records = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < records.count {
            let r = records[i]
            if r.hasPrefix("# branch.oid ") {
                let v = String(r.dropFirst("# branch.oid ".count))
                s.headSHA = v == "(initial)" ? nil : v
            } else if r.hasPrefix("# branch.head ") {
                let v = String(r.dropFirst("# branch.head ".count))
                s.branch = v == "(detached)" ? nil : v
            } else if r.hasPrefix("# branch.upstream ") {
                s.upstream = String(r.dropFirst("# branch.upstream ".count))
            } else if r.hasPrefix("1 ") || r.hasPrefix("u ") {
                s.changed = true
            } else if r.hasPrefix("2 ") {
                // A rename: the next record is the original path.
                s.changed = true
                i += 1
            } else if r.hasPrefix("? ") {
                s.changed = true
                s.untracked = true
            } else if r.hasPrefix("! ") {
                s.ignored = true
            }
            i += 1
        }
        return s
    }
}

/// A GitHub repository named by a remote URL.
public struct GitHubRemote: Equatable, Sendable {
    public var host: String
    public var owner: String
    public var repo: String

    public init(host: String, owner: String, repo: String) { self.host = host; self.owner = owner; self.repo = repo }

    /// `https://host/owner/repo`.
    public var webURL: String { "https://\(host)/\(owner)/\(repo)" }

    /// Parses `remote.origin.url`: `https://host/owner/repo(.git)`,
    /// `git@host:owner/repo(.git)`, `ssh://git@host(:port)/owner/repo(.git)`,
    /// `git://host/owner/repo`. Any host whose name contains "github"
    /// counts (github.com and GitHub Enterprise hosts such as
    /// github.example.com); other hosts give nil.
    public static func parse(_ raw: String) -> GitHubRemote? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        var host: String
        var path: String
        if let schemeEnd = s.range(of: "://") {
            let scheme = s[..<schemeEnd.lowerBound].lowercased()
            guard ["https", "http", "ssh", "git", "git+ssh", "ssh+git"].contains(scheme) else { return nil }
            let rest = s[schemeEnd.upperBound...]
            guard let slash = rest.firstIndex(of: "/") else { return nil }
            var authority = String(rest[..<slash])
            path = String(rest[rest.index(after: slash)...])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            if let colon = authority.lastIndex(of: ":") { authority = String(authority[..<colon]) }
            host = authority
        } else if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {
            // scp-like: [user@]host:owner/repo.git
            var authority = String(s[..<colon])
            if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
            host = authority
            path = String(s[s.index(after: colon)...])
        } else {
            return nil
        }
        host = host.lowercased()
        guard host.contains("github") else { return nil }
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        while path.hasPrefix("/") { path.removeFirst() }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        return GitHubRemote(host: host, owner: parts[0], repo: parts[1])
    }

    /// The file's page at `ref` (a branch or a commit), with `#L10` or
    /// `#L10-L20` for `lines` (1-based, inclusive).
    public func blobURL(ref: String, path: String, lines: ClosedRange<Int>? = nil) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "#?;")
        func enc(_ s: String) -> String {
            s.split(separator: "/", omittingEmptySubsequences: false)
                .map { String($0).addingPercentEncoding(withAllowedCharacters: allowed) ?? String($0) }
                .joined(separator: "/")
        }
        var u = "\(webURL)/blob/\(enc(ref))/\(enc(path))"
        if let lines {
            u += lines.lowerBound == lines.upperBound ? "#L\(lines.lowerBound)" : "#L\(lines.lowerBound)-L\(lines.upperBound)"
        }
        return u
    }
}

/// The gutter's change marks for one file against HEAD.
public struct GitLineChanges: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case added, modified }

    /// Lines (0-based, in the current text) that are new or changed.
    public var lines: [Int: Kind] = [:]
    /// Lines were deleted just above these lines (0-based; the line
    /// count means after the last line).
    public var deletedBefore: Set<Int> = []

    public init() {}

    public var isEmpty: Bool { lines.isEmpty && deletedBefore.isEmpty }

    /// Diffs `base` (HEAD's text) against `current` (the buffer) by line:
    /// in each run of deletions and insertions between unchanged lines, as
    /// many inserted lines as were deleted count as modified and the rest
    /// as added; more deletions than insertions leave a deleted mark below
    /// the run.
    public static func compute(base: String, current: String) -> GitLineChanges {
        compute(ops: LineDiff.diff(LineDiff.lines(base), LineDiff.lines(current)))
    }

    public static func compute(ops: [LineDiff.Op]) -> GitLineChanges {
        var c = GitLineChanges()
        var dels = 0
        var ins: [Int] = []
        // The current line the next insertion or equal line would be.
        var nextLine = 0
        func flush() {
            let modified = min(dels, ins.count)
            for (k, line) in ins.enumerated() { c.lines[line] = k < modified ? .modified : .added }
            if dels > ins.count { c.deletedBefore.insert(nextLine) }
            dels = 0
            ins = []
        }
        for op in ops {
            switch op {
            case .equal(_, let j):
                flush()
                nextLine = j + 1
            case .delete:
                dels += 1
            case .insert(let j):
                ins.append(j)
                nextLine = j + 1
            }
        }
        flush()
        return c
    }

    /// Edits the marks for an edit in the current text before the next
    /// diff arrives: lines after the edit move with it, so marks never sit
    /// on the wrong line while typing.
    public mutating func shift(fromLine first: Int, by delta: Int) {
        guard delta != 0 else { return }
        var moved: [Int: Kind] = [:]
        for (l, k) in lines {
            if l <= first { moved[l] = k } else if l + delta > first { moved[l + delta] = k }
        }
        lines = moved
        deletedBefore = Set(deletedBefore.compactMap { l in l <= first ? l : (l + delta > first ? l + delta : nil) })
    }
}

/// Runs git, off the main thread. Finds a usable git once: one installed
/// outside the system (Homebrew, MacPorts) or `/usr/bin/git` only when the
/// developer tools are installed (without them `/usr/bin/git` is a stub
/// that pops up an install dialog, so Cedric then does nothing).
public enum GitRunner {
    public struct Result: Sendable {
        public var status: Int32
        public var output: Data
        public var text: String { String(decoding: output, as: UTF8.self) }
    }

    /// For tests and checks: a git to use instead of looking.
    nonisolated(unsafe) public static var override: String?

    private static let lock = NSLock()
    nonisolated(unsafe) private static var found: String??

    /// The git executable, or nil. Looked up once (spawns `xcode-select -p`
    /// the first time, so call it off the main thread).
    public static var executable: String? {
        if let override { return override }
        lock.lock()
        defer { lock.unlock() }
        if let found { return found }
        let f = locate()
        found = .some(f)
        return f
    }

    static func locate() -> String? {
        let fm = FileManager.default
        var candidates = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/opt/local/bin/git"]
        // The app's PATH (from launchd) is short; a shell's may name others.
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = "\(dir)/git"
            if p != "/usr/bin/git", !candidates.contains(p) { candidates.append(p) }
        }
        for c in candidates where fm.isExecutableFile(atPath: c) { return c }
        // /usr/bin/git: only with the developer tools installed.
        guard fm.isExecutableFile(atPath: "/usr/bin/git"), fm.isExecutableFile(atPath: "/usr/bin/xcode-select") else { return nil }
        guard let r = launch("/usr/bin/xcode-select", ["-p"], cwd: nil, timeout: 5), r.status == 0 else { return nil }
        let dev = r.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dev.isEmpty, fm.fileExists(atPath: dev) else { return nil }
        return "/usr/bin/git"
    }

    /// Put before every git command: a repository's own config must never
    /// make git run a program (a hostile repo's `core.fsmonitor`, hooks,
    /// diff drivers, pager or credential helper). Cedric also never runs a
    /// command that reads work-tree files through filters (`status`,
    /// `diff`, `add`); see `GitProbe`. Auto gc/maintenance are off so a
    /// `gc.recentObjectsHook` cannot fire; lazy fetch is disabled in env.
    public static let safetyArgs = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "diff.external=",
                                    "-c", "core.pager=cat", "-c", "credential.helper=", "-c", "protocol.allow=never",
                                    "-c", "core.untrackedCache=false",
                                    "-c", "gc.auto=0", "-c", "maintenance.auto=false"]

    /// Env keys set or cleared for every git invocation (not xcode-select).
    public static func applyGitSafety(to env: inout [String: String]) {
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_NO_LAZY_FETCH"] = "1"
        env.removeValue(forKey: "GIT_EXTERNAL_DIFF")
        env.removeValue(forKey: "GIT_CONFIG_PARAMETERS")
        env.removeValue(forKey: "GIT_CONFIG_COUNT")
        env.removeValue(forKey: "GIT_INDEX_FILE")
        env.removeValue(forKey: "GIT_OBJECT_DIRECTORY")
        env.removeValue(forKey: "GIT_ALTERNATE_OBJECT_DIRECTORIES")
        env.removeValue(forKey: "GIT_COMMON_DIR")
    }

    /// Runs `git args` in `cwd`. Nil if git is missing or couldn't start.
    public static func run(_ args: [String], cwd: URL, timeout: TimeInterval = 10) -> Result? {
        guard let git = executable else { return nil }
        return launch(git, args, cwd: cwd, timeout: timeout)
    }

    static func launch(_ path: String, _ args: [String], cwd: URL?, timeout: TimeInterval) -> Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var env = ProcessInfo.processInfo.environment
        // Never take the index lock for a status, never prompt, plain output.
        // Git only: no system config, no external diff (see `safetyArgs`).
        if path != "/usr/bin/xcode-select" {
            p.arguments = safetyArgs + args
            applyGitSafety(to: &env)
        }
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        env.removeValue(forKey: "GIT_DIR")
        env.removeValue(forKey: "GIT_WORK_TREE")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [p] in if p.isRunning { p.terminate() } }
        timer.resume()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        timer.cancel()
        return Result(status: p.terminationStatus, output: data)
    }
}

/// A repository's own config (`.git/config`, `config.worktree` and every
/// file they include) read as `git config --list --includes --show-scope
/// -z` prints it: the keys that would make git run a program. Cedric
/// overrides the ones it knows of on every call and never runs a command
/// that uses the rest, but a repository that asks for any of them gets no
/// git at all (a second layer). Global and system config are the user's
/// own and are trusted.
public enum GitConfigSafety {
    public struct Entry: Equatable, Sendable {
        public var scope: String
        public var key: String
        public var value: String?
    }

    /// Parses `scope\0key\nvalue\0` records (`key` alone for a valueless key).
    public static func parse(_ z: String) -> [Entry] {
        let parts = z.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var out: [Entry] = []
        var i = 0
        while i + 1 < parts.count {
            let scope = parts[i], kv = parts[i + 1]
            if let nl = kv.firstIndex(of: "\n") {
                out.append(Entry(scope: scope, key: String(kv[..<nl]), value: String(kv[kv.index(after: nl)...])))
            } else if !kv.isEmpty {
                out.append(Entry(scope: scope, key: kv, value: nil))
            }
            i += 2
        }
        return out
    }

    /// Scopes that come from the repository (and so from whoever made it).
    static let repoScopes: Set<String> = ["local", "worktree"]

    /// The repository-scoped keys that name a program to run.
    public static func dangerousKeys(_ entries: [Entry]) -> [String] {
        entries.filter { repoScopes.contains($0.scope) && isDangerous(key: $0.key, value: $0.value) }.map(\.key)
    }

    static func isBool(_ v: String?) -> Bool {
        guard let v = v?.lowercased() else { return true }
        return ["", "true", "false", "yes", "no", "on", "off", "1", "0"].contains(v)
    }

    public static func isDangerous(key rawKey: String, value: String?) -> Bool {
        // Section and name are case-insensitive; a subsection is not.
        let parts = rawKey.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2 else { return false }
        let section = parts[0].lowercased(), name = parts[parts.count - 1].lowercased()
        let hasSub = parts.count > 2
        let sub = hasSub ? parts[1..<(parts.count - 1)].joined(separator: ".") : ""
        switch section {
        case "core":
            switch name {
            // A boolean fsmonitor is git's own daemon, not a command.
            case "fsmonitor": return !isBool(value)
            // core.hooksPath is not here: safetyArgs pins it to /dev/null, and
            // husky-style repos set it routinely (refusing them would turn
            // git info off for ordinary JavaScript projects).
            case "sshcommand", "gitproxy", "askpass", "editor", "pager", "alternaterefscommand": return true
            default: return false
            }
        case "filter":
            guard hasSub, ["clean", "smudge", "process"].contains(name) else { return false }
            // `git lfs install --local`: Git LFS's own, fixed commands.
            if sub == "lfs", let v = value, ["git-lfs clean -- %f", "git-lfs smudge -- %f", "git-lfs filter-process"].contains(v) { return false }
            return true
        case "diff": return name == "external" || (hasSub && ["textconv", "command"].contains(name))
        case "merge": return hasSub && name == "driver"
        case "credential": return name == "helper"
        case "gpg": return name == "program"
        case "sequence": return name == "editor"
        case "uploadpack": return name == "packobjectshook"
        case "gc": return name == "recentobjectshook"
        case "pager": return true
        case "remote": return hasSub && ["uploadpack", "receivepack", "vcs"].contains(name)
        case "ssh": return name == "variant"
        default: return false
        }
    }

    /// The value of `key` (exact, case-insensitive section/name) last set in any scope.
    public static func value(_ entries: [Entry], _ key: String) -> String? {
        entries.last { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

/// What git says about one file, using only commands that never run a
/// repository's programs or filters: `config --list` (read), `rev-parse`,
/// `cat-file blob <id>` (raw bytes, no textconv or smudge) and `ls-files`
/// (index only, fsmonitor off). No `status`, `diff` or `show`. Whether
/// the file changed comes from comparing its bytes on disk with HEAD's.
public struct GitProbe: Sendable {
    /// Non-empty: the repository's config asks to run programs, so the
    /// rest was not looked at.
    public var refusedKeys: [String] = []
    public var status = GitFileStatus()
    /// The path from the work tree's root (when asked for).
    public var relativePath: String?
    public var remoteURL: String?
    /// HEAD's blob for the file; nil when it isn't in HEAD.
    public var blobID: String?
    /// HEAD's bytes for the file: "" when it is only in the index, nil when
    /// untracked or ignored.
    public var base: Data?

    public var refused: Bool { !refusedKeys.isEmpty }

    /// `cached`: HEAD's blob id and bytes from the last probe (reused when
    /// the blob hasn't changed, so `cat-file` runs only when it did).
    public static func probe(file: URL, location: GitLocation, cached: (id: String, data: Data)? = nil) -> GitProbe? {
        let dir = file.deletingLastPathComponent(), name = file.lastPathComponent
        guard let cfg = GitRunner.run(["config", "--list", "--includes", "--show-scope", "-z"], cwd: dir), cfg.status == 0 else { return nil }
        let entries = GitConfigSafety.parse(cfg.text)
        var p = GitProbe()
        p.refusedKeys = GitConfigSafety.dangerousKeys(entries)
        if p.refused { return p }
        p.remoteURL = GitConfigSafety.value(entries, "remote.origin.url")
        guard let pre = GitRunner.run(["rev-parse", "--show-prefix"], cwd: dir), pre.status == 0 else { return nil }
        let rel = pre.text.trimmingCharacters(in: .newlines) + name
        p.relativePath = rel
        let head = (try? String(contentsOf: location.gitDir.appendingPathComponent("HEAD"), encoding: .utf8)).flatMap(GitHead.parse)
        if case .branch(let b) = head {
            p.status.branch = b
            p.status.upstream = GitConfigSafety.value(entries, "branch.\(b).merge")
        }
        if let h = GitRunner.run(["rev-parse", "-q", "--verify", "HEAD^{commit}"], cwd: dir), h.status == 0 {
            p.status.headSHA = h.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if p.status.headSHA != nil,
           let b = GitRunner.run(["rev-parse", "-q", "--verify", "HEAD:\(rel)"], cwd: dir), b.status == 0 {
            let id = b.text.trimmingCharacters(in: .whitespacesAndNewlines)
            p.blobID = id
            if let cached, cached.id == id {
                p.base = cached.data
            } else if let c = GitRunner.run(["cat-file", "blob", id], cwd: dir), c.status == 0 {
                p.base = c.output
            } else {
                return nil
            }
        } else if let l = GitRunner.run(["ls-files", "-z", "--", name], cwd: dir), l.status == 0, !l.output.isEmpty {
            // Staged, not yet committed: every line is new.
            p.base = Data()
        } else if let i = GitRunner.run(["ls-files", "-z", "-o", "-i", "--exclude-standard", "--", name], cwd: dir),
                  i.status == 0, !i.output.isEmpty {
            p.status.ignored = true
        } else {
            p.status.untracked = true
        }
        if p.status.untracked {
            p.status.changed = true
        } else if let base = p.base {
            let disk = try? Data(contentsOf: file, options: .mappedIfSafe)
            p.status.changed = disk != base
        }
        return p
    }
}
