import Foundation
import Testing
@testable import CedricCore

/// The `.obsidian` walk-up never makes the vault the home folder, a folder
/// above it, `/`, a top-level folder or a volume root (0.5.2, S2).
@Suite struct WikiVaultBoundsTests {
    @Test func aStrayObsidianInHomeIsNotAVault() throws {
        let t = try makeTree(["home/.obsidian/app.json", "home/Secrets/key.md", "home/Notes/sub/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let home = t.appendingPathComponent("home")
        let doc = t.appendingPathComponent("home/Notes/sub")
        #expect(WikiVault.obsidianRoot(above: doc, home: home) == nil)
        let vault = WikiVault(documentFolder: doc, home: home)
        #expect(vault.root.path == doc.standardizedFileURL.path, "falls back to the document's own folder")
        #expect(vault.resolve("key") == nil, "a note elsewhere in home is out of reach")
        #expect(vault.resolve("/Secrets/key") == nil)
    }

    @Test func aNoteSavedStraightInHomeDoesNotIndexAllOfHome() throws {
        let t = try makeTree(["home/note.md", "home/Beside.md", "home/Documents/Private/secret.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let home = t.appendingPathComponent("home")
        let vault = WikiVault(documentFolder: home, home: home)
        #expect(vault.indexDepth == 1)
        #expect(vault.resolve("Beside")?.lastPathComponent == "Beside.md", "the folder's own notes still resolve")
        #expect(vault.resolve("secret") == nil, "a bare name doesn't search the rest of home")
        // An ordinary folder keeps the full depth.
        #expect(WikiVault(documentFolder: t.appendingPathComponent("home/Documents"), home: home).indexDepth == WikiVault.maxDepth)
        // Opening the home folder on purpose keeps the full index.
        #expect(WikiVault(documentFolder: home, openedRoot: home, home: home).indexDepth == WikiVault.maxDepth)
    }

    @Test func anObsidianAboveHomeIsNotAVault() throws {
        let t = try makeTree(["users/.obsidian/x", "users/me/Notes/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let home = t.appendingPathComponent("users/me")
        #expect(WikiVault.obsidianRoot(above: t.appendingPathComponent("users/me/Notes"), home: home) == nil)
    }

    @Test func aRealVaultInsideHomeIsStillFound() throws {
        let t = try makeTree(["home/.obsidian/x", "home/Vault/.obsidian/app.json", "home/Vault/a/b/doc.md", "home/Vault/Other.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let home = t.appendingPathComponent("home")
        let vault = WikiVault(documentFolder: t.appendingPathComponent("home/Vault/a/b"), home: home)
        #expect(vault.root.path == t.appendingPathComponent("home/Vault").standardizedFileURL.path)
        #expect(vault.resolve("Other")?.lastPathComponent == "Other.md")
    }

    @Test func anOpenedFolderStillWins() throws {
        let t = try makeTree(["home/.obsidian/x", "home/Notes/doc.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let home = t.appendingPathComponent("home")
        let vault = WikiVault(documentFolder: t.appendingPathComponent("home/Notes"), openedRoot: home, home: home)
        #expect(vault.root.path == home.standardizedFileURL.path, "the user chose to open the home folder")
    }

    @Test func boundaryFolders() {
        let home = URL(fileURLWithPath: "/Users/someone")
        let no = ["/", "/Users", "/Users/someone", "/Volumes", "/Volumes/Backup", "/tmp"]
        for p in no { #expect(!WikiVault.mayBeVaultRoot(URL(fileURLWithPath: p), home: home), "\(p)") }
        let yes = ["/Users/someone/Notes", "/Volumes/Backup/Vault", "/Users/other/Vault"]
        for p in yes { #expect(WikiVault.mayBeVaultRoot(URL(fileURLWithPath: p), home: home), "\(p)") }
    }

    /// A symbolic link to a volume (the data volume, an external disk, any
    /// mount point) is held to the same bounds as the volume itself:
    /// `isVolume` and the path rules apply to the resolved path too.
    @Test func aSymlinkToAVolumeIsNotAVault() throws {
        let t = try makeTree([])
        defer { try? FileManager.default.removeItem(at: t) }
        let fm = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory())
        // Fixed targets present on every macOS runner: the root volume and
        // (when the system is split) the data volume.
        var targets = ["/", "/System/Volumes/Data"].filter { fm.fileExists(atPath: $0) }
        // Other mounted volumes (/Volumes/<disk> ones and deeper mount
        // points) only when the volume itself is refused: a network or
        // Time Machine mount (e.g. /Volumes/.timemachine/<host>/<id>/backups)
        // may refuse to report `isVolume` (permission denied); since 0.6.1
        // that refusal is itself a refusal (`aFolderWhoseVolumeCantBeRead…`),
        // but which mounts there are depends on the machine. The point here
        // is that the link gets the same answer as its target.
        let mounted = fm.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: []) ?? []
        targets += mounted.map(\.path).filter { path in
            !targets.contains(path) && !WikiVault.mayBeVaultRoot(URL(fileURLWithPath: path), home: home)
        }
        #expect(!targets.isEmpty)
        for (n, target) in targets.enumerated() {
            let link = t.appendingPathComponent("link\(n)")
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: target)
            #expect(!WikiVault.mayBeVaultRoot(link, home: home), "link to \(target)")
            #expect(WikiVault(documentFolder: link, home: home).indexDepth == 1, "link to \(target): a note there doesn't index the volume")
        }
    }

    // MARK: A failed metadata read (0.6.1: Sol's nit on f550641)

    /// How `isVolume` reads are classified, on real folders made here:
    /// an ordinary folder, the root volume, a missing path, and a folder
    /// whose parent can't be searched (EACCES, as an unreadable mount
    /// answers). No mounted volume other than `/` is touched.
    @Test func volumeReadsAreClassified() throws {
        let t = try makeTree(["locked/inside/.obsidian/app.json", "locked/inside/doc.md"])
        let locked = t.appendingPathComponent("locked")
        defer {
            chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: t)
        }
        #expect(WikiVault.readIsVolume(t) == .notVolume)
        #expect(WikiVault.readIsVolume(URL(fileURLWithPath: "/")) == .volume)
        #expect(WikiVault.readIsVolume(t.appendingPathComponent("no/such/folder")) == .missing)
        #expect(WikiVault.readIsVolume(t.appendingPathComponent("locked/inside/doc.md/below")) == .missing, "ENOTDIR")
        let inside = t.appendingPathComponent("locked/inside")
        #expect(WikiVault.mayBeVaultRoot(inside, home: t.appendingPathComponent("home")), "readable: an ordinary folder")
        try #require(chmod(locked.path, 0o000) == 0)
        // Root can search any folder: nothing to check then.
        guard geteuid() != 0 else { return }
        #expect(WikiVault.readIsVolume(inside) == .unreadable, "permission denied")
        #expect(!WikiVault.mayBeVaultRoot(inside, home: t.appendingPathComponent("home")),
                "a folder whose isVolume can't be read is refused (0.6.0: allowed)")
    }

    /// Sol's gap: a mount that can be read, so the walk finds its
    /// `.obsidian`, but whose `isVolume` read fails, and whose path passes
    /// the path rules (not /Volumes/<disk>). It is refused, so a note on it
    /// gets its own folder, not the whole mount as its vault; the same tree
    /// read normally still finds the vault.
    @Test func aMountWhoseVolumeReadFailsIsNotAVault() throws {
        let t = try makeTree(["mnt/share/.obsidian/app.json", "mnt/share/Notes/doc.md", "mnt/share/Private/secret.md"])
        defer { try? FileManager.default.removeItem(at: t) }
        let home = t.appendingPathComponent("home")
        let share = t.appendingPathComponent("mnt/share").standardizedFileURL
        let notes = t.appendingPathComponent("mnt/share/Notes")
        func failing(at failed: URL, _ answer: WikiVault.VolumeRead) -> (URL) -> WikiVault.VolumeRead {
            { url in
                let p = url.standardizedFileURL.resolvingSymlinksInPath().path
                return p == failed.resolvingSymlinksInPath().path ? answer : WikiVault.readIsVolume(url)
            }
        }
        #expect(WikiVault.obsidianRoot(above: notes, home: home, volume: WikiVault.readIsVolume)?.path == share.path,
                "read normally: an ordinary vault, found")
        #expect(WikiVault.obsidianRoot(above: notes, home: home, volume: failing(at: share, .unreadable)) == nil,
                "its isVolume read failed: not a vault root, and the walk stops there")
        #expect(WikiVault.obsidianRoot(above: notes, home: home, volume: failing(at: share, .volume)) == nil,
                "as for a mount that says it is one")
        #expect(!WikiVault.mayBeVaultRoot(share, home: home, volume: failing(at: share, .unreadable)))
        // A failure on the folder below the vault stops the walk there too.
        #expect(WikiVault.obsidianRoot(above: notes, home: home, volume: failing(at: notes.standardizedFileURL, .unreadable)) == nil)
        // A missing answer is not a refusal: the path rules decide.
        #expect(WikiVault.mayBeVaultRoot(share, home: home, volume: { _ in .missing }))
    }
}
