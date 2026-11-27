import Foundation
import Testing
@testable import CedricCore

/// A watcher event and a directory listing spell paths independently
/// (Astra batch 17v must 5): the listing's spelling stays the key; an
/// event that misses it by bytes is matched to a listed folder by
/// identity, or relists a known ancestor. Aliases are real APFS folders
/// (case and NFD variants of a listed name); two canonically equivalent
/// folders can't both exist on APFS, so twins go through the seams.
@Suite struct WatcherSpellingTests {
    let fm = FileManager.default
    let nfc = "caf\u{E9}", nfd = "cafe\u{301}"

    /// Made with Darwin calls on byte paths: Foundation's file URLs and
    /// path APIs decompose an NFC name, and the NFC folder must stay NFC.
    func tree() throws -> URL {
        let root = fm.temporaryDirectory.appendingPathComponent("cedric-watch-\(UUID().uuidString)").resolvingSymlinksInPath()
        let r = root.path
        for d in ["", "/Docs", "/Docs/Deep", "/" + nfc] { #expect(mkdir(r + d, 0o755) == 0) }
        for (f, t) in [("/Docs/a.txt", "a"), ("/Docs/Deep/d.txt", "d"), ("/" + nfc + "/c.txt", "c")] { put(r + f, t) }
        return root
    }

    func put(_ path: String, _ text: String) {
        let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        #expect(fd >= 0, "made \(path)")
        _ = text.withCString { write(fd, $0, strlen($0)) }
        close(fd)
    }

    func sameFolder(_ a: URL, _ b: URL) -> Bool {
        Beneath.FileID(path: a.path, followLast: true).map { $0 == Beneath.FileID(path: b.path, followLast: true) } ?? false
    }

    // MARK: Open Quickly

    @Test func openQuicklyRefreshesAFolderNamedInAnotherSpelling() throws {
        let root = try tree(); defer { try? fm.removeItem(at: root) }
        guard sameFolder(root.appendingPathComponent("Docs"), root.appendingPathComponent("DOCS")) else { return }
        #expect(try fm.contentsOfDirectory(atPath: root.path).contains { FolderTree.sameBytes($0, nfc) }, "the folder is listed as NFC")
        var idx = FileIndex.build(root: root, showHidden: false)
        put(root.path + "/Docs/b.txt", "b")
        put(root.path + "/Docs/Deep/e.txt", "e")
        put(root.path + "/" + nfc + "/n.txt", "n")
        // The events spell the folders otherwise than the listing did.
        idx.refresh("DOCS", recursive: false)
        idx.refresh("docs/DEEP", recursive: false)
        idx.refresh(nfd, recursive: false)
        let paths = Set(idx.paths)
        #expect(paths.contains("Docs/b.txt"), "a case variant of a listed folder is that folder")
        #expect(paths.contains("Docs/Deep/e.txt"), "…at any depth")
        #expect(paths.contains { FolderTree.sameBytes($0, nfc + "/n.txt") }, "an NFD event for an NFC folder is that folder")
        // Still keyed by the listing's spelling, never the event's.
        #expect(!paths.contains { $0.utf8.starts(with: "DOCS".utf8) || $0.utf8.starts(with: nfd.utf8) })
        #expect(idx.paths.count == paths.count)
    }

    @Test func openQuicklyRelistsTheParentOfAFolderGoneUnderAnotherSpelling() throws {
        let root = try tree(); defer { try? fm.removeItem(at: root) }
        guard sameFolder(root.appendingPathComponent("Docs"), root.appendingPathComponent("DOCS")) else { return }
        var idx = FileIndex.build(root: root, showHidden: false)
        try fm.removeItem(at: root.appendingPathComponent("Docs/Deep"))
        idx.refresh("DOCS/DEEP", recursive: false)
        #expect(!idx.paths.contains("Docs/Deep/d.txt"), "the known ancestor is listed again and drops it")
    }

    @Test func openQuicklyKeepsTwinFoldersApart() {
        var idx = FileIndex(root: URL(fileURLWithPath: "/nonexistent-cedric"), showHidden: false, limit: 100)
        idx.dirs[""] = FileIndex.Dir(files: [], subdirs: [nfc, nfd])
        idx.dirs[nfc] = FileIndex.Dir(files: ["one.txt"], subdirs: [])
        idx.dirs[nfd] = FileIndex.Dir(files: ["two.txt"], subdirs: [])
        #expect(Set(idx.paths.map { Array($0.utf8) }) == Set([Array((nfc + "/one.txt").utf8), Array((nfd + "/two.txt").utf8)]))
    }

    // MARK: The resolver (identity seam)

    /// Two canonically equivalent folders, as a volume that keeps names
    /// as bytes holds them: different identities.
    func twins(_ root: URL) -> (subfolders: (String) -> [String]?, identity: (String) -> Beneath.FileID?) {
        let r = root.path
        let ids: [FolderTree.PathKey: Beneath.FileID] = [
            FolderTree.PathKey(r + "/" + nfc): Beneath.FileID(dev: 9, ino: 1),
            FolderTree.PathKey(r + "/" + nfd): Beneath.FileID(dev: 9, ino: 2),
            // A case variant of the NFD one, which that volume folds to it.
            FolderTree.PathKey(r + "/CAFE\u{301}"): Beneath.FileID(dev: 9, ino: 2),
            FolderTree.PathKey(r + "/other"): Beneath.FileID(dev: 9, ino: 3),
        ]
        return ({ $0.isEmpty ? [self.nfc, self.nfd] : nil }, { ids[FolderTree.PathKey($0)] })
    }

    @Test func twinsAreMatchedByBytesThenByTheirOwnIdentity() {
        let root = URL(fileURLWithPath: "/vol/notes")
        let t = twins(root)
        func find(_ rel: String) -> FolderTree.ListedFolder {
            FolderTree.listedFolder(rel, base: root.path, root: root, subfolders: t.subfolders, identity: t.identity)
        }
        #expect(find(nfc) == .listed(nfc))
        #expect(find(nfd) == .listed(nfd))
        if case .listed(let k) = find("CAFE\u{301}") {
            #expect(FolderTree.sameBytes(k, nfd), "the variant is the twin it is the same folder as, not the first listed")
        } else { Issue.record("variant not found") }
        #expect(find("other") == .unlisted, "there, but not listed: skipped")
        #expect(find("GONE") == .ancestor(""), "gone: its listed parent is listed again")
    }

    @Test func anEventUnderAnotherSpellingOfTheRootIsInIt() throws {
        let root = try tree(); defer { try? fm.removeItem(at: root) }
        let variant = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent.uppercased())
        guard sameFolder(root, variant) else { return }
        let e = FolderTree.eventRelativePath(variant.path + "/Docs", roots: [root])
        #expect(e?.rel == "Docs" && e?.base == variant.path)
        #expect(FolderTree.eventRelativePath(root.path + "/Docs", roots: [root])?.rel == "Docs")
        #expect(FolderTree.eventRelativePath(root.deletingLastPathComponent().path, roots: [root]) == nil)
    }

    // MARK: Sidebar

    @Test func sidebarTwinsGetTheirOwnNodes() {
        let parent = FolderNode(root: URL(fileURLWithPath: "/vol/notes", isDirectory: true))
        let listing = [FolderEntry(name: nfc, isDirectory: true), FolderEntry(name: nfd, isDirectory: true)]
        parent.apply(listing)
        parent.apply(listing)
        let c = parent.children ?? []
        #expect(c.count == 2 && c[0] !== c[1], "two folders, two nodes")
        // (Their URLs can't differ: a file URL decomposes both names to NFD. Open item.)
        #expect(parent.listedDescendant(nfd) === c[1] && parent.listedDescendant(nfc) === c[0])
    }

    @Test func sidebarFindsALoadedFolderFromAnEventInAnotherSpelling() throws {
        let root = try tree(); defer { try? fm.removeItem(at: root) }
        guard sameFolder(root.appendingPathComponent("Docs"), root.appendingPathComponent("DOCS")) else { return }
        let top = FolderNode(root: root)
        top.apply(try FolderTree.list(root, showHidden: false))
        let docs = try #require(top.listedDescendant("Docs"))
        docs.apply(try FolderTree.list(docs.url, showHidden: false))
        let e = try #require(FolderTree.eventRelativePath(root.path + "/DOCS/DEEP", roots: [root]))
        let found = FolderTree.listedFolder(e.rel, base: e.base, root: root) { top.listedDescendant($0)?.children?.filter(\.isDirectory).map(\.name) }
        #expect(found == .listed("Docs/Deep"))
    }

    // MARK: Wiki rescan

    @Test func aChangedFolderInAnotherSpellingRescansItsNotes() throws {
        let root = try tree(); defer { try? fm.removeItem(at: root) }
        guard sameFolder(root.appendingPathComponent("Docs"), root.appendingPathComponent("DOCS")) else { return }
        put(root.path + "/Docs/n.md", "[[x]]")
        put(root.path + "/" + nfc + "/m.md", "[[y]]")
        let notes = ["Docs/n.md", nfc + "/m.md"]
        var scan = BacklinkScan(root: root)
        scan.update(notes: notes, dirty: nil)
        #expect(scan.lastRead == 2)
        put(root.path + "/Docs/n.md", "[[x]] [[z]]")
        put(root.path + "/" + nfc + "/m.md", "[[y]] [[w]]")
        scan.update(notes: notes, dirty: [FolderTree.PathKey("DOCS"), FolderTree.PathKey(nfd)])
        #expect(scan.lastRead == 2, "both changed folders are read again though the events spell them otherwise")
    }

    /// Two notes under the two twin spellings of one folder name. APFS
    /// folds them into one real folder; the seam gives each spelling its
    /// own identity, as a volume that keeps names as bytes would.
    @Test func aChangedTwinRescansOnlyItsOwnNotes() throws {
        let root = try tree(); defer { try? fm.removeItem(at: root) }
        guard sameFolder(root.appendingPathComponent(nfc), root.appendingPathComponent(nfd)) else { return }
        put(root.path + "/" + nfc + "/a.md", "[[x]]")
        put(root.path + "/" + nfc + "/b.md", "[[y]]")
        let notes = [nfc + "/a.md", nfd + "/b.md"]
        let t = twins(root)
        var probes = 0
        let identity: (String) -> Beneath.FileID? = { probes += 1; return t.identity($0) }
        var scan = BacklinkScan(root: root)
        scan.update(notes: notes, dirty: nil, identity: identity)
        #expect(scan.lastRead == 2)
        put(root.path + "/" + nfc + "/a.md", "[[x]] [[z]]")
        put(root.path + "/" + nfc + "/b.md", "[[y]] [[w]]")
        // The NFC folder changed, by its own bytes: only its note, no identity probe needed.
        scan.update(notes: notes, dirty: [FolderTree.PathKey(nfc)], identity: identity)
        #expect(scan.lastRead == 1 && probes == 0, "the NFC twin's note only: read \(scan.lastRead), probes \(probes)")
        put(root.path + "/" + nfc + "/b.md", "[[y]] [[w]] [[v]]")
        // A variant of the NFD twin: by identity, the NFD folder, not the NFC one.
        scan.update(notes: notes, dirty: [FolderTree.PathKey("CAFE\u{301}")], identity: identity)
        #expect(scan.lastRead == 1 && scan.files[nfd + "/b.md"]?.refs.count == 3, "the NFD twin's note only: read \(scan.lastRead)")
    }
}
