import Foundation
import Testing
@testable import CedricCore

/// cedric://open?untitled= and wait= paths: only the script's own temp files.
@Suite struct CLIHandoffTests {
    let fm = FileManager.default

    /// A fresh "temp folder" and a fresh "home" outside it.
    func dirs() throws -> (temp: String, home: String) {
        let root = NSTemporaryDirectory() + "cedric-handoff-test-\(UUID().uuidString)"
        try fm.createDirectory(atPath: root + "/T", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: root + "/home/x", withIntermediateDirectories: true)
        return (root + "/T", root + "/home")
    }

    func cleanup(_ d: (temp: String, home: String)) { try? fm.removeItem(atPath: (d.temp as NSString).deletingLastPathComponent) }

    @Test func theScriptsOwnFileIsAccepted() throws {
        let d = try dirs(); defer { cleanup(d) }
        let p = d.temp + "/cedric-stdin.Ab12Cd"
        try "piped".write(toFile: p, atomically: false, encoding: .utf8)
        let u = CLIHandoff.accept(p, kind: .stdin, tempDirs: [d.temp])
        #expect(u?.path == CLIHandoff.realpath(p))
        let w = d.temp + "/cedric-wait.Zz99yy"
        try "".write(toFile: w, atomically: false, encoding: .utf8)
        #expect(CLIHandoff.accept(w, kind: .wait, tempDirs: [d.temp]) != nil)
        // Each kind only its own prefix.
        #expect(CLIHandoff.accept(w, kind: .stdin, tempDirs: [d.temp]) == nil)
    }

    @Test func dotDotOutOfTheTempFolderIsRefused() throws {
        let d = try dirs(); defer { cleanup(d) }
        let victim = d.home + "/x/cedric-stdin.victim"
        try "precious".write(toFile: victim, atomically: false, encoding: .utf8)
        #expect(CLIHandoff.accept(d.temp + "/../home/x/cedric-stdin.victim", kind: .stdin, tempDirs: [d.temp]) == nil)
        // The attack as reported: a temp-looking prefix, then `..`.
        #expect(CLIHandoff.accept("/private/../" + victim, kind: .stdin, tempDirs: [d.temp]) == nil)
        #expect(CLIHandoff.accept(d.temp + "/../home/x/victim.txt", kind: .stdin, tempDirs: [d.temp]) == nil)
        // `..` that stays inside is fine (it resolves to the temp folder).
        try fm.createDirectory(atPath: d.temp + "/sub", withIntermediateDirectories: true)
        try "ok".write(toFile: d.temp + "/cedric-stdin.abcdef", atomically: false, encoding: .utf8)
        #expect(CLIHandoff.accept(d.temp + "/sub/../cedric-stdin.abcdef", kind: .stdin, tempDirs: [d.temp]) != nil)
    }

    @Test func symlinksAreRefused() throws {
        let d = try dirs(); defer { cleanup(d) }
        let victim = d.home + "/x/victim.txt"
        try "precious".write(toFile: victim, atomically: false, encoding: .utf8)
        // A correctly named symlink in the temp folder pointing outside.
        try fm.createSymbolicLink(atPath: d.temp + "/cedric-stdin.link01", withDestinationPath: victim)
        #expect(CLIHandoff.accept(d.temp + "/cedric-stdin.link01", kind: .stdin, tempDirs: [d.temp]) == nil)
        // A symlinked folder inside the temp folder that leads outside.
        try fm.createSymbolicLink(atPath: d.temp + "/out", withDestinationPath: d.home + "/x")
        try "precious".write(toFile: d.home + "/x/cedric-stdin.abcdef", atomically: false, encoding: .utf8)
        #expect(CLIHandoff.accept(d.temp + "/out/cedric-stdin.abcdef", kind: .stdin, tempDirs: [d.temp]) == nil)
        // A hard link to a file elsewhere.
        try fm.linkItem(atPath: victim, toPath: d.temp + "/cedric-stdin.hard01")
        #expect(CLIHandoff.accept(d.temp + "/cedric-stdin.hard01", kind: .stdin, tempDirs: [d.temp]) == nil)
        #expect(fm.fileExists(atPath: victim))
    }

    @Test func aHardLinkToAVictimIsRefused() throws {
        let d = try dirs(); defer { cleanup(d) }
        let victim = d.home + "/x/victim.txt"
        try "precious".write(toFile: victim, atomically: false, encoding: .utf8)
        let link = d.temp + "/cedric-stdin.HardL1"
        try fm.linkItem(atPath: victim, toPath: link)
        #expect((try fm.attributesOfItem(atPath: link)[.referenceCount] as? NSNumber)?.intValue == 2, "nlink 2")
        #expect(CLIHandoff.inspect(link, kind: .stdin, tempDirs: [d.temp], read: true) == nil)
        #expect(CLIHandoff.inspect(d.temp + "/cedric-wait.HardL1", kind: .wait, tempDirs: [d.temp]) == nil)
        #expect((try? String(contentsOfFile: victim, encoding: .utf8)) == "precious")
    }

    @Test func wrongNamesAreRefused() throws {
        let d = try dirs(); defer { cleanup(d) }
        for name in ["victim.txt", "cedric-stdin.", "cedric-stdin.abc", "cedric-stdin.ab cd ef", "cedric-stdin.abc-def", "xcedric-stdin.abcdef"] {
            let p = d.temp + "/" + name
            try "x".write(toFile: p, atomically: false, encoding: .utf8)
            #expect(CLIHandoff.accept(p, kind: .stdin, tempDirs: [d.temp]) == nil, "\(name)")
        }
        #expect(CLIHandoff.accept("cedric-stdin.abcdef", kind: .stdin, tempDirs: [d.temp]) == nil, "relative path")
        #expect(CLIHandoff.accept(d.temp + "/cedric-stdin.gone00", kind: .stdin, tempDirs: [d.temp]) == nil, "missing file")
    }

    @Test func otherOwnersAndFoldersAreRefused() throws {
        let d = try dirs(); defer { cleanup(d) }
        let p = d.temp + "/cedric-stdin.abcdef"
        try "x".write(toFile: p, atomically: false, encoding: .utf8)
        #expect(CLIHandoff.accept(p, kind: .stdin, tempDirs: [d.temp], uid: getuid() &+ 1) == nil, "owned by someone else")
        try fm.createDirectory(atPath: d.temp + "/cedric-stdin.dir000", withIntermediateDirectories: true)
        #expect(CLIHandoff.accept(d.temp + "/cedric-stdin.dir000", kind: .stdin, tempDirs: [d.temp]) == nil, "a folder")
        // Right name, wrong folder (a shared one).
        #expect(CLIHandoff.accept(p, kind: .stdin, tempDirs: [d.home]) == nil)
    }

    @Test func theRealHandOffReadsThenDeletes() throws {
        let d = try dirs(); defer { cleanup(d) }
        let p = d.temp + "/cedric-stdin.Q1w2E3"
        try "from stdin\n".write(toFile: p, atomically: false, encoding: .utf8)
        let h = try #require(CLIHandoff.inspect(p, kind: .stdin, tempDirs: [d.temp], read: true))
        #expect(h.data == Data("from stdin\n".utf8))
        #expect(CLIHandoff.remove(h))
        #expect(!fm.fileExists(atPath: p))
    }

    @Test func aFileSwappedAfterTheCheckIsNotDeleted() throws {
        let d = try dirs(); defer { cleanup(d) }
        let p = d.temp + "/cedric-wait.Swap00"
        try "".write(toFile: p, atomically: false, encoding: .utf8)
        let h = try #require(CLIHandoff.inspect(p, kind: .wait, tempDirs: [d.temp]))
        // Replaced by a link to a victim file (the TOCTOU case).
        let victim = d.home + "/x/victim.txt"
        try "precious".write(toFile: victim, atomically: false, encoding: .utf8)
        try fm.removeItem(atPath: p)
        try fm.createSymbolicLink(atPath: p, withDestinationPath: victim)
        #expect(!CLIHandoff.remove(h))
        #expect(fm.fileExists(atPath: p) && fm.fileExists(atPath: victim))
        // Or by another regular file: a different inode, also left alone.
        try fm.removeItem(atPath: p)
        try "other".write(toFile: p, atomically: false, encoding: .utf8)
        #expect(!CLIHandoff.remove(h) && fm.fileExists(atPath: p))
    }

    @Test func rootOwnedSystemFilesAreRefused() {
        // Read-only evidence: /etc/hosts is root's; never modified here.
        #expect(CLIHandoff.inspect("/etc/hosts", kind: .stdin, tempDirs: ["/etc"]) == nil)
        #expect(CLIHandoff.inspect("/private/etc/../etc/hosts", kind: .stdin) == nil)
    }

    @Test func tokenIsPrivateRandomAndCompared() throws {
        let d = try dirs(); defer { cleanup(d) }
        let u = URL(fileURLWithPath: d.home + "/Cedric/cli-token")
        let t = try #require(CLIToken.ensure(at: u))
        #expect(t.count == 32)
        #expect(CLIToken.ensure(at: u) == t, "made once, then read")
        let mode = (try fm.attributesOfItem(atPath: u.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        #expect(CLIToken.matches(t, t))
        #expect(!CLIToken.matches(nil, t) && !CLIToken.matches("", t) && !CLIToken.matches("x" + t.dropFirst(), t))
        #expect(!CLIToken.matches(t, nil))
        // A token file others can read isn't trusted.
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: u.path)
        #expect(CLIToken.read(u) == nil)
    }

    @Test func refusalsNeverCarryTheToken() {
        let secret = String(repeating: "ab12", count: 8)
        let url = "cedric://open?untitled=/tmp/x&token=\(secret)&wait=/tmp/y"
        for msg in [CLIToken.refusal(url, secret: secret), CLIToken.refusal("bad path /tmp/\(secret)", secret: secret),
                    CLIToken.refusal("cedric://open?path=/a&TOKEN%3D\(secret)"), CLIToken.refusal(url)] {
            #expect(!msg.contains(secret), "\(msg)")
            #expect(msg.hasPrefix("cedric://: refused ("))
        }
        #expect(CLIToken.redacted(url).contains("token=•••&wait=/tmp/y"))
    }

    /// The temp folder is matched by device and inode, not by the text of
    /// its resolved path (Astra batch 17v): a case or normalization variant
    /// of the folder's own name is the same folder on APFS and is taken; a
    /// different folder is refused however its path reads.
    @Test func theTempFolderIsMatchedByIdentityNotSpelling() throws {
        let base = NSTemporaryDirectory() + "cedric-handoff-id-\(UUID().uuidString)"
        defer { try? fm.removeItem(atPath: base) }
        let nfc = "Caf\u{E9}T", nfd = "cafe\u{301}t"   // one folder on APFS: case and normalization differ
        try fm.createDirectory(atPath: base + "/" + nfc, withIntermediateDirectories: true)
        let other = base + "/Other"
        try fm.createDirectory(atPath: other, withIntermediateDirectories: true)
        try "piped".write(toFile: base + "/" + nfc + "/cedric-stdin.Ab12Cd", atomically: false, encoding: .utf8)
        try "elsewhere".write(toFile: other + "/cedric-stdin.Ab12Cd", atomically: false, encoding: .utf8)
        guard Beneath.FileID(path: base + "/" + nfd, followLast: true) == Beneath.FileID(path: base + "/" + nfc, followLast: true) else {
            return   // a case- and normalization-sensitive TMPDIR: nothing to alias
        }
        // The file named through the variant spelling, the temp folder given in the original.
        let h = CLIHandoff.inspect(base + "/" + nfd + "/cedric-stdin.Ab12Cd", kind: .stdin, tempDirs: [base + "/" + nfc], read: true)
        #expect(h.map { String(decoding: $0.data ?? Data(), as: UTF8.self) } == "piped")
        // And the other way round.
        #expect(CLIHandoff.accept(base + "/" + nfc + "/cedric-stdin.Ab12Cd", kind: .stdin, tempDirs: [base + "/" + nfd]) != nil)
        // A different folder isn't the temp folder.
        #expect(CLIHandoff.accept(other + "/cedric-stdin.Ab12Cd", kind: .stdin, tempDirs: [base + "/" + nfc]) == nil)
        // A slash followed by a combining mark starts an absolute path (its first byte).
        #expect(CLIHandoff.accept("/\u{301}nowhere/cedric-stdin.Ab12Cd", kind: .stdin, tempDirs: [base + "/" + nfc]) == nil)
    }

    /// The temp folder given through another path to the same folder (the
    /// Data volume's firmlinked spelling, which realpath keeps as written):
    /// the same device and inode, so the script's file is taken; the text
    /// of the two resolved paths differs.
    @Test func theTempFolderByAnotherPathToItIsTheSameFolder() throws {
        let d = try dirs(); defer { cleanup(d) }
        guard let real = CLIHandoff.realpath(d.temp) else { Issue.record("no temp"); return }
        let alias = "/System/Volumes/Data" + real
        guard Beneath.FileID(path: alias, followLast: true) == Beneath.FileID(path: real, followLast: true),
              CLIHandoff.realpath(alias) != real else { return }   // no firmlinked Data volume here
        try "piped".write(toFile: d.temp + "/cedric-stdin.Ab12Cd", atomically: false, encoding: .utf8)
        #expect(CLIHandoff.accept(d.temp + "/cedric-stdin.Ab12Cd", kind: .stdin, tempDirs: [alias]) != nil)
        #expect(CLIHandoff.accept(alias + "/cedric-stdin.Ab12Cd", kind: .stdin, tempDirs: [d.temp]) != nil)
        // Still never a folder that isn't it.
        try "x".write(toFile: d.home + "/cedric-stdin.Ab12Cd", atomically: false, encoding: .utf8)
        #expect(CLIHandoff.accept("/System/Volumes/Data" + (CLIHandoff.realpath(d.home) ?? d.home) + "/cedric-stdin.Ab12Cd",
                                  kind: .stdin, tempDirs: [alias]) == nil)
    }
}
