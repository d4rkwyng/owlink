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
        // may refuse to report `isVolume` (permission denied), so what it
        // reads as depends on the machine. The point here is that the link
        // gets the same answer as its target, not how each mount reads.
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
}
