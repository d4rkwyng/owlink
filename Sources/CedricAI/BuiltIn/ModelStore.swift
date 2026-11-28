import CryptoKit
import Foundation
import CedricCore

/// Where downloaded models live: `~/Library/Application Support/Cedric/Models/`.
///
/// - `<fileName>`: a finished, verified model;
/// - `<fileName>.verified`: the SHA-256 it was verified against (a model is
///   "installed" only when the file has the catalog's size and this marker
///   matches the catalog's hash, so a catalog update re-downloads);
/// - `.partial/<fileName>.part`: an unfinished download, resumable.
public struct ModelStore: Sendable {
    public let directory: URL

    public init(directory: URL = ModelStore.defaultDirectory) {
        self.directory = directory
    }

    /// CEDRIC_MODELS_DIR=/dir overrides it (the app checks use a temp dir):
    /// the folder that path resolves to (symbolic links, then ".."), fixed
    /// once per process, which is the one CheckIsolation validates. Never
    /// the raw string, which could name a different folder by the time it
    /// is opened.
    public static var defaultDirectory: URL {
        if let dir = CheckIsolation.processModelsOverride { return dir }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Cedric/Models", isDirectory: true)
    }

    var partialDirectory: URL { directory.appendingPathComponent(".partial", isDirectory: true) }

    public func fileURL(for model: BuiltInModel) -> URL { directory.appendingPathComponent(model.fileName) }
    func markerURL(for model: BuiltInModel) -> URL { directory.appendingPathComponent(model.fileName + ".verified") }
    public func partialURL(for model: BuiltInModel) -> URL { partialDirectory.appendingPathComponent(model.fileName + ".part") }

    public func cleanTargetEntries(for model: BuiltInModel) -> [URL] {
        [fileURL(for: model), markerURL(for: model), stampURL(for: model), partialURL(for: model)]
    }

    public func isInstalled(_ model: BuiltInModel) -> Bool {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: fileURL(for: model).path),
              (attrs[.size] as? NSNumber)?.int64Value == model.sizeBytes,
              let mark = try? String(contentsOf: markerURL(for: model), encoding: .utf8) else { return false }
        return mark.trimmingCharacters(in: .whitespacesAndNewlines) == model.sha256
    }

    func stampURL(for model: BuiltInModel) -> URL { directory.appendingPathComponent(model.fileName + ".loadcheck") }

    /// Whether the installed file is still the catalog's (security review
    /// 0.2.1): the size and marker say "installed", but llama.cpp parses
    /// the file inside Owlink's process, so before a load its SHA-256 is
    /// checked against the catalog's (bundled, signed) value. Hashing a
    /// model takes a few seconds, so it is done once and remembered with
    /// the file's device, inode, size, modification time and status-change
    /// time (ctime): the first load after an install, or after the file
    /// changed or was replaced, hashes again. A symbolic link or a mismatch
    /// is refused. Blocking: call it off the main thread.
    ///
    /// The mtime can be set back by any process of the user (utimensat),
    /// so on its own it would let a rewritten file keep its old stamp; the
    /// ctime can't be set from user space and moves on any write, chmod or
    /// utimensat. A stamp written before ctime was in it (0.2.1 betas)
    /// doesn't match and just hashes once more.
    ///
    /// This is defence in depth, not a seal: the check is by path and
    /// LlamaRuntime.load then opens the file again by path, so a process
    /// running as the user that swaps the file between the two is not
    /// caught (a known gap, see docs/architecture.md).
    public func verifiedForLoad(_ model: BuiltInModel) -> Bool {
        let url = fileURL(for: model)
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int64(st.st_size) == model.sizeBytes else { return false }
        let stamp = Self.loadStamp(st, sha256: model.sha256)
        if let saved = try? String(contentsOf: stampURL(for: model), encoding: .utf8),
           saved.trimmingCharacters(in: .whitespacesAndNewlines) == stamp { return true }
        guard let digest = Self.sha256Hex(ofFileAt: url), digest == model.sha256.lowercased() else { return false }
        // Hashed what was there at the stat above only if it is still the same file.
        var after = stat()
        guard lstat(url.path, &after) == 0, Self.loadStamp(after, sha256: model.sha256) == stamp else { return false }
        try? PrivateDirectory.writePrivateFile(Data((stamp + "\n").utf8), to: stampURL(for: model))
        return true
    }

    /// The .loadcheck line: device, inode, size, mtime, ctime and the
    /// catalog hash the file was checked against.
    static func loadStamp(_ st: stat, sha256: String) -> String {
        "\(st.st_dev) \(st.st_ino) \(st.st_size) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
            + " c\(st.st_ctimespec.tv_sec).\(st.st_ctimespec.tv_nsec) \(sha256)"
    }

    /// The file's SHA-256 (lowercase hex), read in 4 MB pieces without
    /// following a symbolic link; nil if it can't be read.
    static func sha256Hex(ofFileAt url: URL) -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try h.read(upToCount: 4 << 20) } catch { return nil }
            guard let chunk, !chunk.isEmpty else { break }  // nil or empty: the end
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Bytes already downloaded for an unfinished download (0 if none).
    public func partialBytes(_ model: BuiltInModel) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: partialURL(for: model).path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    public func installed(in catalog: ModelCatalog) -> [BuiltInModel] { catalog.models.filter(isInstalled) }

    /// Removes the model, its verification marker, its load-check stamp, and any partial download.
    public func delete(_ model: BuiltInModel) throws {
        let fm = FileManager.default
        for url in cleanTargetEntries(for: model) where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    func prepare() throws {
        try PrivateDirectory.make(partialDirectory)
    }

    /// Moves a verified partial into place and writes its marker.
    func install(_ model: BuiltInModel, from partial: URL) throws {
        let fm = FileManager.default
        let dest = fileURL(for: model)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: partial, to: dest)
        try model.sha256.write(to: markerURL(for: model), atomically: true, encoding: .utf8)
        // Models are re-downloadable; keep them out of Time Machine.
        var url = dest
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Free space for new files on the volume holding `url` (walks up to an
    /// existing ancestor), as the system counts it for important downloads.
    public static func freeSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe = probe.deletingLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }
}
