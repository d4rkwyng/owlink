import AppKit
import CedricCore

/// File › Open Quickly… (⌥⌘O): the folder sidebar's files for the command
/// palette's file mode (QuickOpen.swift in CedricCore has the index and
/// the ranking).
///
/// - **Built on first use**, off the main thread (a serial queue): opening
///   a folder costs nothing until Open Quickly is used in it. The palette
///   shows "Indexing…" until the index lands, then fills in.
/// - **Kept fresh by the sidebar's folder watcher** (FolderWatcher): each
///   changed folder is listed again, not the tree (`FileIndex.refresh`);
///   a folder holding a .gitignore, or coalesced events, re-list the
///   subtree. Changes arriving while a job runs are batched for the next.
/// - **Stale when the watcher stops** (the sidebar hidden): the next use
///   lists the folder again. Show Hidden Files makes a new index.
@MainActor
final class QuickOpenFiles {
    let root: URL
    /// The root's real path (FSEvents reports real paths).
    let realRoot: String
    let showHidden: Bool
    private(set) var index: FileIndex?
    private(set) var matcher: FileMatchIndex?
    private var running = false
    /// Folders to list again, by their relative paths' bytes.
    private var pending: [FolderTree.PathKey: Bool] = [:]
    private var pendingFull = false
    private var stale = false
    /// The index (or a refresh of it) landed (the palette shows it).
    var onUpdate: (() -> Void)?
    /// The same, for the `[[` note names (WikiNotes).
    var onIndexLanded: (() -> Void)?
    /// Full builds and folder refreshes done (the checks).
    private(set) var builds = 0, refreshes = 0
    /// How long the last full build took (listing and preparing), in ms.
    private(set) var lastBuildMilliseconds: Double = 0
    private static let queue = DispatchQueue(label: "cedric.quick-open", qos: .userInitiated)

    init(root: URL, realRoot: String, showHidden: Bool) {
        self.root = root
        self.realRoot = realRoot
        self.showHidden = showHidden
    }

    var isIndexing: Bool { running }
    var truncated: Bool { index?.truncated ?? false }

    /// Builds the index if there is none (or it went stale).
    func ensure() {
        guard index == nil || stale else { return }
        if running { pendingFull = true } else { startBuild() }
    }

    /// The watcher stopped: changes are no longer seen.
    func markStale() { stale = true }

    private func startBuild() {
        stale = false
        pendingFull = false
        pending = [:]
        running = true
        let root = root, hidden = showHidden, ref = WeakRef(self)
        Self.queue.async {
            let t0 = CACurrentMediaTime()
            let idx = FileIndex.build(root: root, showHidden: hidden)
            let result = MainBox(value: (idx, FileMatchIndex(paths: idx.paths)))
            let ms = (CACurrentMediaTime() - t0) * 1000
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ref.value?.lastBuildMilliseconds = ms
                    ref.value?.builds += 1
                    ref.value?.landed(result.value.0, result.value.1)
                }
            }
        }
    }

    private func landed(_ idx: FileIndex, _ m: FileMatchIndex) {
        index = idx
        matcher = m
        running = false
        onUpdate?()
        onIndexLanded?()
        drain()
    }

    /// Runs what queued up while a job ran.
    private func drain() {
        guard !running else { return }
        if pendingFull || stale { startBuild(); return }
        guard !pending.isEmpty, var idx = index else { return }
        // Parents before children: a new folder is walked from its parent.
        let jobs = pending.sorted { a, b in
            let da = FolderTree.components(a.key.string).count, db = FolderTree.components(b.key.string).count
            return da != db ? da < db : a.key.string < b.key.string
        }.map { ($0.key.string, $0.value) }
        pending = [:]
        running = true
        let ref = WeakRef(self), box = MainBox(value: jobs)
        Self.queue.async {
            for (rel, recursive) in box.value { idx.refresh(rel, recursive: recursive) }
            let result = MainBox(value: (idx, FileMatchIndex(paths: idx.paths)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    ref.value?.refreshes += box.value.count
                    ref.value?.landed(result.value.0, result.value.1)
                }
            }
        }
    }

    /// FolderWatcher events (FolderSidebar.handle). Nothing to do until the
    /// index has been asked for.
    func handle(_ changes: [FolderWatcher.Change]) {
        guard index != nil || running else { return }
        func rel(_ p: String) -> String? {
            let u = URL(fileURLWithPath: p)
            return FolderTree.relativePath(of: u, in: URL(fileURLWithPath: realRoot)) ?? FolderTree.relativePath(of: u, in: root)
        }
        for c in changes {
            switch c {
            case .rootChanged: pendingFull = true
            case .folder(let p):
                guard let r = rel(p) else { continue }
                let gitignore = FileManager.default.fileExists(atPath: (p as NSString).appendingPathComponent(".gitignore"))
                pending[FolderTree.PathKey(r)] = gitignore || pending[FolderTree.PathKey(r)] == true
            case .subtree(let p):
                if let r = rel(p) { pending[FolderTree.PathKey(r)] = true }
            }
        }
        drain()
    }
}

extension AppDelegate {
    /// File › Open Quickly… (⌥⌘O): the command palette in file mode.
    @objc func openQuicklyMenu(_ sender: Any?) {
        let key = NSApp.keyWindow
        let over = (key is PalettePanel ? nil : key) ?? NSApp.mainWindow
            ?? NSApp.orderedWindows.first { $0.isVisible && !($0 is PalettePanel) && $0.windowController != nil }
        CommandPalette.toggle(over: over, mode: .files)
    }
}

extension FolderSidebar {
    /// The Open Quickly index for this folder (made on first use).
    var quickOpenFiles: QuickOpenFiles {
        if let q = quickOpen, q.showHidden == showHidden { return q }
        let q = QuickOpenFiles(root: rootURL, realRoot: realRoot, showHidden: showHidden)
        quickOpen = q
        return q
    }
}
