import AppKit
import CedricCore

/// The owl's facts that need the disk, read lazily and off the main thread.
///
/// `FileProbe` answers Markdown's "does this relative link's file exist?":
/// the first time a path is asked it isn’t known (nil, the rule skips it)
/// and a stat runs on a background queue; the next query (at most one per
/// 30 s) has the answer. Answers are kept for 2 min, so a file made or
/// renamed since is seen again soon. Nothing here runs before the first
/// frame: the owl only asks after it.
final class FileProbe: @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    // By the path's bytes (`FolderTree.PathKey`): a `String` key gave a
    // canonically equivalent name the other's answer.
    private var known: [FolderTree.PathKey: (exists: Bool, at: Date)] = [:]
    private var pending: Set<FolderTree.PathKey> = []
    private static let queue = DispatchQueue(label: "owlink.owl.file-probe", qos: .utility)
    static let lifetime: TimeInterval = 120

    init(folder: URL) { self.folder = folder }

    /// The probe the rules call: relative path → exists, or nil (checking).
    /// Made on the main thread (`owlFacts`), called from the rules.
    lazy var rulesProbe: OwlFileProbe = OwlFileProbe(exists: { [weak self] rel in self?.exists(rel) ?? nil },
                                                     files: { [weak self] in self?.files() })

    private var tree: (files: [String], at: Date)?
    private var scanning = false

    /// The Markdown and image files under the folder (for a broken link's
    /// nearest-file Fix it): the cached list, or nil the first time while
    /// `OwlFileProbe.scan` lists the folder on the utility queue (at most
    /// 2,000 entries). Kept for the same 2 min as the answers; an older
    /// list is still returned while a fresh one is made.
    func files() -> [String]? {
        lock.lock()
        defer { lock.unlock() }
        let fresh = tree.map { Date().timeIntervalSince($0.at) < Self.lifetime } ?? false
        if !fresh, !scanning {
            scanning = true
            let folder = self.folder
            Self.queue.async { [weak self] in
                let list = OwlFileProbe.scan(folder: folder)
                guard let self else { return }
                self.lock.lock()
                self.tree = (list, Date())
                self.scanning = false
                self.lock.unlock()
            }
        }
        return tree?.files
    }

    func exists(_ rel: String) -> Bool? {
        let path = folder.appendingPathComponent(rel).standardizedFileURL.path
        let key = FolderTree.PathKey(path)
        lock.lock()
        defer { lock.unlock() }
        if let k = known[key], Date().timeIntervalSince(k.at) < Self.lifetime { return k.exists }
        if known.count > 2000 { known.removeAll() }
        guard pending.insert(key).inserted else { return nil }
        Self.queue.async { [weak self] in
            let e = FileManager.default.fileExists(atPath: path)
            guard let self else { return }
            self.lock.lock()
            self.known[key] = (e, Date())
            self.pending.remove(key)
            self.lock.unlock()
        }
        return nil
    }
}

extension EditorWindowController {
    /// Markdown files with a folder get the file probe (made on first use,
    /// replaced when the file moves).
    func owlFileProbe() -> OwlFileProbe? {
        guard doc.language == .markdown, let folder = doc.fileURL?.deletingLastPathComponent(), OwlFileProbe.probes(folder: folder) else { return nil }
        if let p = fileProbe, p.folder == folder { return p.rulesProbe }
        let p = FileProbe(folder: folder)
        fileProbe = p
        return p.rulesProbe
    }
}

/// Downloaded scripts: the offer to check one is made once per file, ever
/// (a short list of paths in UserDefaults, newest last).
enum DownloadedScriptOffers {
    static let key = "owlDownloadedScriptOffered"
    static let limit = 200

    static func offered(_ path: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).contains(path)
    }

    static func note(_ path: String) {
        var list = UserDefaults.standard.stringArray(forKey: key) ?? []
        list.removeAll { $0 == path }
        list.append(path)
        if list.count > limit { list.removeFirst(list.count - limit) }
        UserDefaults.standard.set(list, forKey: key)
    }

    /// Whether the file has the quarantine attribute (it was downloaded).
    static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }
}

extension EditorWindowController {
    /// A script was opened: after the first frame, the quarantine attribute
    /// is read off the main thread; if it's there (and the offer wasn't made
    /// for this file before) the owl gets to offer the check.
    func readQuarantineForOwl() {
        guard ScriptSafety.isScript(doc.language), let url = doc.fileURL, !DownloadedScriptOffers.offered(url.path) else { return }
        AfterFirstFrame.run { [weak self] in
            DispatchQueue.global(qos: .utility).async {
                let q = DownloadedScriptOffers.isQuarantined(url)
                guard q else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.doc.fileURL == url else { return }
                        self.quarantined = true
                        if self.owl != nil { OwlHub.shared.activity(in: self) }
                    }
                }
            }
        }
    }

    /// The fact for the rules: downloaded, and not offered for this file yet.
    var owlQuarantined: Bool {
        guard quarantined, let path = doc.fileURL?.path else { return false }
        return !DownloadedScriptOffers.offered(path)
    }
}

/// `.editorconfig` for the owl's whitespace rules: read lazily (on the
/// owl's first query for a file, then once per file location), off the
/// main thread, walking up from the file's folder to the config with
/// `root = true` (or the top). The first query goes without it; the next
/// one has it.
enum EditorConfigReader {
    static func values(for file: URL) -> EditorConfig.Values? {
        var configs: [(EditorConfig.File, String)] = []
        var dir = file.deletingLastPathComponent()
        let name = file.lastPathComponent
        var rel = name
        for _ in 0..<40 {
            let url = dir.appendingPathComponent(".editorconfig")
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                let f = EditorConfig.parse(text)
                configs.insert((f, rel), at: 0)
                if f.root { break }
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            rel = dir.lastPathComponent + "/" + rel
            dir = parent
        }
        guard !configs.isEmpty else { return nil }
        let v = EditorConfig.values(for: configs.map(\.1), configs: configs.map(\.0))
        return v.isEmpty ? nil : v
    }
}

extension EditorWindowController {
    /// The `.editorconfig` values for this file, if read (see EditorConfigReader).
    func owlEditorConfig() -> EditorConfig.Values? {
        guard let url = doc.fileURL else { return nil }
        if editorConfigFor == url { return editorConfigValues }
        guard editorConfigPending != url else { return nil }
        editorConfigPending = url
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let v = EditorConfigReader.values(for: url)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.editorConfigPending == url else { return }
                    self.editorConfigFor = url
                    self.editorConfigValues = v
                    self.editorConfigPending = nil
                }
            }
        }
        return nil
    }
}
