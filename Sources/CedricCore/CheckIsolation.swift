import Foundation

/// The isolation the app checks that open Settings › Cedric need before they
/// build the pane or touch the built-in downloads (CEDRIC_CHECK=settings,
/// CEDRIC_BUILTIN_CHECK): the AI settings in a UserDefaults suite of their
/// own (CEDRIC_AI_DEFAULTS, a generated `cedric-check-…` name, never the
/// app's standard domain or some other program's), and the models in a
/// folder of their own (CEDRIC_MODELS_DIR, an existing folder outside
/// ~/Library, so never Application Support/Cedric/Models). Without both, a
/// check's clicks could save over the user's model choice or download and
/// delete the user's models.
///
/// The folder is judged as the file system sees it: the path is resolved
/// in file system order (each symbolic link where it stands, then the ".."
/// after it; `realpath`), and "inside ~/Library" is asked of each ancestor
/// folder's device and inode, not of the spelling (a case-insensitive
/// volume, a firmlink). `ModelStore` opens that same resolved folder, not
/// the string in the environment.
public enum CheckIsolation {
    /// Why a run is refused.
    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
    }

    // MARK: The defaults suite

    /// Every check suite's name starts with this.
    public static let suitePrefix = "cedric-check-"

    /// A check's own suite: `cedric-check-` then 1 to 64 ASCII letters,
    /// digits or hyphens (what the check scripts generate). Nothing else:
    /// no other program's domain, no path, no spelling variant.
    public static func isCheckSuiteName(_ name: String) -> Bool {
        let bytes = Array(name.utf8), prefix = Array(suitePrefix.utf8)
        guard bytes.starts(with: prefix) else { return false }
        let rest = bytes.dropFirst(prefix.count)
        guard (1...64).contains(rest.count) else { return false }
        return rest.allSatisfy { b in
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) || b == 0x2D
        }
    }

    // MARK: The models folder

    /// `path` as the file system resolves it (symbolic links first, then
    /// ".."), when it is an existing folder; nil otherwise.
    public static func canonicalDirectory(_ path: String) -> String? {
        guard path.hasPrefix("/"), let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        let resolved = String(cString: p)
        var st = stat()
        guard stat(resolved, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return resolved
    }

    /// Where CEDRIC_MODELS_DIR points: the resolved folder, or (a folder
    /// not made yet, which no check accepts) the path as given.
    public static func modelsDirectoryOverride(_ env: [String: String]) -> URL? {
        guard let dir = env["CEDRIC_MODELS_DIR"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: canonicalDirectory(dir) ?? dir, isDirectory: true)
    }

    /// This process's CEDRIC_MODELS_DIR, resolved once: what `ModelStore`
    /// opens and what `processModelsDirectory()` validates are one value.
    public static let processModelsOverride: URL? = modelsDirectoryOverride(DevEnvironment.values)
    private static let processCanonical: String? = DevEnvironment.values["CEDRIC_MODELS_DIR"].flatMap { canonicalDirectory($0) }

    /// Whether anything (a file, a folder, a dangling link) has this name.
    public static func entryExists(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0
    }

    /// Why `dir` is not a folder a check may fill, or nil: it must be the
    /// user's own and hold nothing at all (hidden entries count).
    public static func ownedEmptyFolderProblem(_ dir: URL) -> String? {
        var st = stat()
        guard lstat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return "\(dir.path) is not a folder" }
        guard st.st_uid == getuid() else { return "\(dir.path) belongs to another user" }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return "\(dir.path) can't be listed" }
        if names.isEmpty { return nil }
        let shown = names.sorted().prefix(3).joined(separator: ", ")
        return "\(dir.path) is not empty (\(names.count): \(shown)\(names.count > 3 ? ", …" : ""))"
    }

    // MARK: The guard

    /// Whether `path` (resolved: no links or ".." left in it) is `folder`
    /// or inside it, by each ancestor's device and inode: the spelling
    /// (letter case on a case-insensitive volume, a firmlink, a link in
    /// `folder`'s own path) doesn't matter. nil: something on the way
    /// can't be examined. A `folder` that doesn't exist holds nothing.
    static func isInside(_ path: String, folder: String) -> Bool? {
        var target = stat()
        if stat(folder, &target) != 0 { return errno == ENOENT ? false : nil }
        var at = path
        while true {
            var st = stat()
            guard stat(at, &st) == 0 else { return nil }
            if st.st_dev == target.st_dev && st.st_ino == target.st_ino { return true }
            if at == "/" { return false }
            at = (at as NSString).deletingLastPathComponent
            if at.isEmpty { at = "/" }
        }
    }

    /// The validated models folder (resolved), or why this run is not
    /// isolated. `standardDomains`: the suite names that are the app's own
    /// defaults (its bundle ID and process name, the global domain).
    public static func modelsDirectory(_ env: [String: String],
                                       home: String = NSHomeDirectory(),
                                       standardDomains: Set<String> = defaultStandardDomains) -> Result<URL, Refusal> {
        validated(env, home: home, standardDomains: standardDomains, canonical: canonicalDirectory)
    }

    /// `canonical`: CEDRIC_MODELS_DIR as the folder that is opened.
    private static func validated(_ env: [String: String], home: String, standardDomains: Set<String>,
                                  canonical: (String) -> String?) -> Result<URL, Refusal> {
        func refuse(_ why: String) -> Result<URL, Refusal> { .failure(Refusal(reason: why)) }
        let suite = env["CEDRIC_AI_DEFAULTS"] ?? ""
        if suite.isEmpty { return refuse("CEDRIC_AI_DEFAULTS is not set (the AI settings would be the user's own)") }
        if standardDomains.contains(suite) { return refuse("CEDRIC_AI_DEFAULTS=\(suite) is the app's standard defaults domain") }
        guard isCheckSuiteName(suite) else {
            return refuse("CEDRIC_AI_DEFAULTS=\(suite) is not a check's own suite (\(suitePrefix) then letters, digits or hyphens)")
        }
        guard UserDefaults(suiteName: suite) != nil else { return refuse("CEDRIC_AI_DEFAULTS=\(suite) is the app's standard defaults domain") }
        let dir = env["CEDRIC_MODELS_DIR"] ?? ""
        if dir.isEmpty { return refuse("CEDRIC_MODELS_DIR is not set (the models folder would be the user's own)") }
        guard dir.hasPrefix("/") else { return refuse("CEDRIC_MODELS_DIR=\(dir) is not an absolute path") }
        guard let path = canonical(dir) else { return refuse("CEDRIC_MODELS_DIR=\(dir) is not an existing folder") }
        // Fail closed: a Library or an ancestor that can't be examined.
        let library = (home as NSString).appendingPathComponent("Library")
        guard let inside = isInside(path, folder: library) else { return refuse("CEDRIC_MODELS_DIR=\(dir): its folders can't be examined") }
        // Also any Application Support/Cedric, whoever's home it is in.
        if inside || (path + "/").range(of: "/Application Support/Cedric/", options: .caseInsensitive) != nil {
            return refuse("CEDRIC_MODELS_DIR=\(dir) is inside ~/Library")
        }
        return .success(URL(fileURLWithPath: path, isDirectory: true))
    }

    /// Why this run is not isolated, or nil when it is.
    public static func problem(_ env: [String: String],
                               home: String = NSHomeDirectory(),
                               standardDomains: Set<String> = defaultStandardDomains) -> String? {
        if case .failure(let refusal) = modelsDirectory(env, home: home, standardDomains: standardDomains) { return refusal.reason }
        return nil
    }

    /// This process: the validated models folder, which is the one
    /// `ModelStore` opens (CEDRIC_MODELS_DIR as resolved once, at first
    /// use), or why the run is not isolated. Refused too if that path no
    /// longer resolves to itself (a link put in its place since).
    public static func processModelsDirectory() -> Result<URL, Refusal> {
        _ = processModelsOverride
        return validated(DevEnvironment.values, home: NSHomeDirectory(), standardDomains: defaultStandardDomains) { _ in
            guard let fixed = processCanonical, canonicalDirectory(fixed) == fixed else { return nil }
            return fixed
        }
    }

    public static var defaultStandardDomains: Set<String> {
        Set([Bundle.main.bundleIdentifier, ProcessInfo.processInfo.processName, "NSGlobalDomain", ".GlobalPreferences"]
            .compactMap { $0 }.filter { !$0.isEmpty })
    }
}

/// The files a check puts in its own folder: each is created only if
/// nothing has its name, and only those files are removed afterwards (and
/// only while they are still the files that were created), so a check
/// never truncates or deletes a file it found.
public final class CheckOwnedFiles {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    private var created: [(path: String, device: dev_t, inode: ino_t)] = []

    public init() {}

    /// The paths this object created and has not removed.
    public var paths: [String] { created.map(\.path) }

    /// Creates `url` (O_EXCL: fails if a file, folder or link has the
    /// name) with `contents`, then sets its length to `size` if given (a
    /// sparse file).
    public func create(_ url: URL, contents: Data = Data(), size: Int64? = nil) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw Failure(description: "\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw Failure(description: "\(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        created.append((url.path, st.st_dev, st.st_ino))
        let wrote = contents.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard wrote == contents.count else { throw Failure(description: "\(url.lastPathComponent): short write") }
        if let size, ftruncate(fd, off_t(size)) != 0 {
            throw Failure(description: "\(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// Removes the files this object created that are still those files
    /// (same device and inode). Returns the paths it left alone because
    /// something else now has the name.
    @discardableResult
    public func removeAll() -> [String] {
        var left: [String] = []
        for file in created {
            var st = stat()
            guard lstat(file.path, &st) == 0 else { continue }   // already gone
            if st.st_dev == file.device && st.st_ino == file.inode { unlink(file.path) } else { left.append(file.path) }
        }
        created = []
        return left
    }
}
