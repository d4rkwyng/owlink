import Foundation
import Testing
@testable import CedricCore

/// A file the user can't write (chmod 444, locked in the Finder, on a
/// read-only volume) is read-only in its tab: Cedric's Apply is off and a
/// save never replaces it (0.5.2 wrote over a 0444 file with an atomic
/// rename). Real files in a temporary folder.
@Suite struct ReadOnlyFileTests {
    /// A fresh folder with `name` holding `text`; removed (flags and modes
    /// cleared first) by `cleanUp`.
    func file(_ name: String = "readonly.md", _ text: String = "# Read me\n\nTry editing it.\n") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-ro-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func cleanUp(_ url: URL) {
        let dir = url.deletingLastPathComponent()
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let p = dir.appendingPathComponent(f).path
            _ = chflags(p, 0)
            _ = chmod(p, 0o644)
        }
        try? FileManager.default.removeItem(at: dir)
    }

    func mode(_ url: URL) -> mode_t {
        var st = stat()
        _ = stat(url.path, &st)
        return st.st_mode & 0o7777
    }

    @Test func chmod444IsReadOnly() throws {
        let url = try file()
        defer { cleanUp(url) }
        #expect(FileWriteAccess.blocked(at: url) == nil, "a 0644 file the user owns is writable")
        #expect(chmod(url.path, 0o444) == 0)
        // Owned by this user, in a writable folder: still read-only (the real-use repro).
        #expect(FileWriteAccess.blocked(at: url) == .permissions)
        #expect(chmod(url.path, 0o400) == 0)
        #expect(FileWriteAccess.blocked(at: url) == .permissions)
    }

    @Test func aMissingFileIsNotBlocked() throws {
        let url = try file()
        defer { cleanUp(url) }
        #expect(FileWriteAccess.blocked(at: url.deletingLastPathComponent().appendingPathComponent("new.md")) == nil)
    }

    @Test func theFinderLockIsReadOnly() throws {
        let url = try file()
        defer { cleanUp(url) }
        try #require(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0, "chflags uchg on a temp file")
        #expect(mode(url) & 0o200 != 0, "the mode still says writable")
        #expect(FileWriteAccess.blocked(at: url) == .locked)
        #expect(chflags(url.path, 0) == 0)
        #expect(FileWriteAccess.blocked(at: url) == nil, "unlocked: writable again")
    }

    @Test func aReadOnlyVolumeIsReadOnly() throws {
        // The sealed system volume is mounted read-only.
        let sys = URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist")
        try #require(FileManager.default.fileExists(atPath: sys.path))
        #expect(FileWriteAccess.blocked(at: sys) == .readOnlyVolume)
    }

    @Test func permissionChangesWhileOpenAreSeenOnTheNextCheck() throws {
        let url = try file()
        defer { cleanUp(url) }
        // Opened writable.
        let opened = try String(contentsOf: url, encoding: .utf8)
        #expect(FileWriteAccess.blocked(at: url) == nil)
        // chmod 444 while the tab is open: the next check (save, window key, Apply) sees it.
        #expect(chmod(url.path, 0o444) == 0)
        #expect(FileWriteAccess.blocked(at: url) == .permissions)
        #expect(throws: ReadOnlyFileError(url: url, reason: .permissions)) {
            try DocumentWrite.write(Data((opened + "typed\n").utf8), to: url)
        }
        // chmod 644 again: editable and savable.
        #expect(chmod(url.path, 0o644) == 0)
        #expect(FileWriteAccess.blocked(at: url) == nil)
        try DocumentWrite.write(Data((opened + "typed\n").utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == opened + "typed\n")
    }

    @Test func saveRefusesToReplaceAReadOnlyFile() throws {
        let url = try file()
        defer { cleanUp(url) }
        let before = try Data(contentsOf: url)
        #expect(chmod(url.path, 0o444) == 0)
        #expect(throws: ReadOnlyFileError(url: url, reason: .permissions)) {
            try DocumentWrite.write(Data("overwritten\n".utf8), to: url)
        }
        #expect(try Data(contentsOf: url) == before, "the bytes are unchanged")
        #expect(mode(url) == 0o444, "the mode is unchanged")

        // Locked: refused too, though the mode allows writing.
        #expect(chmod(url.path, 0o644) == 0)
        try #require(chflags(url.path, UInt32(UF_IMMUTABLE)) == 0)
        #expect(throws: ReadOnlyFileError(url: url, reason: .locked)) {
            try DocumentWrite.write(Data("overwritten\n".utf8), to: url)
        }
        #expect(try Data(contentsOf: url) == before)
        #expect(chflags(url.path, 0) == 0)

        // Writable: the save goes through.
        try DocumentWrite.write(Data("saved\n".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "saved\n")
    }

    @Test func aLinkToAReadOnlyFileIsRefusedAndStaysALink() throws {
        let target = try file("target.md", "target\n")
        defer { cleanUp(target) }
        let link = target.deletingLastPathComponent().appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "target.md")
        #expect(chmod(target.path, 0o444) == 0)
        #expect(FileWriteAccess.blocked(at: link) == .permissions, "the target decides, not the link")
        #expect(throws: ReadOnlyFileError.self) { try DocumentWrite.write(Data("x\n".utf8), to: link) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == "target.md")
        #expect(try String(contentsOf: target, encoding: .utf8) == "target\n")
    }

    /// The save guard and the write used to resolve the link separately:
    /// retargeted in between, a writable file was checked and a read-only
    /// one replaced (the atomic rename only needs the folder). Now the
    /// target checked is the target written.
    @Test func aLinkRetargetedAfterTheCheckStillWritesTheCheckedFile() throws {
        let writable = try file("writable.md", "writable\n")
        defer { cleanUp(writable) }
        let dir = writable.deletingLastPathComponent()
        let locked = dir.appendingPathComponent("readonly.md")
        try Data("read-only\n".utf8).write(to: locked)
        #expect(chmod(locked.path, 0o444) == 0)
        let link = dir.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "writable.md")
        #expect(FileWriteAccess.blocked(at: link) == nil)

        try DocumentWrite.write(Data("saved\n".utf8), to: link, fileManager: .default) {
            // Between the check and the write: the link now points at the read-only file.
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "readonly.md")
        }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n", "the read-only file is untouched")
        #expect(mode(locked) == 0o444)
        #expect(try String(contentsOf: writable, encoding: .utf8) == "saved\n", "the checked file got the save")
        // And the plain save through the retargeted link is refused, as before.
        #expect(throws: ReadOnlyFileError.self) { try DocumentWrite.write(Data("x\n".utf8), to: link) }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n")
    }

    /// The same race one folder up (Codex review, 0.5.4): the file is
    /// reached through a link to a folder. Checked through it, then the
    /// folder link retargeted at a folder holding a read-only file of the
    /// same name: a write by path followed the link again and its rename
    /// replaced that file. The check and the write now share one open
    /// folder.
    @Test func aFolderLinkRetargetedAfterTheCheckStillWritesTheCheckedFolder() throws {
        let anchor = try file("anchor.md", "anchor\n")
        defer { cleanUp(anchor) }
        let base = anchor.deletingLastPathComponent()
        let fm = FileManager.default
        let good = base.appendingPathComponent("good"), bad = base.appendingPathComponent("bad")
        try fm.createDirectory(at: good, withIntermediateDirectories: false)
        try fm.createDirectory(at: bad, withIntermediateDirectories: false)
        defer { cleanUp(good.appendingPathComponent("doc.md")); cleanUp(bad.appendingPathComponent("doc.md")) }
        let writable = good.appendingPathComponent("doc.md"), locked = bad.appendingPathComponent("doc.md")
        try Data("writable\n".utf8).write(to: writable)
        try Data("read-only\n".utf8).write(to: locked)
        #expect(chmod(locked.path, 0o444) == 0)
        let folderLink = base.appendingPathComponent("folder")
        try fm.createSymbolicLink(atPath: folderLink.path, withDestinationPath: "good")
        let url = folderLink.appendingPathComponent("doc.md")
        #expect(FileWriteAccess.blocked(at: url) == nil)

        try DocumentWrite.write(Data("saved\n".utf8), to: url, fileManager: .default) {
            // Between the check and the write: the folder link now points at the folder with the read-only file.
            try? fm.removeItem(at: folderLink)
            try? fm.createSymbolicLink(atPath: folderLink.path, withDestinationPath: "bad")
        }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n", "the read-only file is untouched")
        #expect(mode(locked) == 0o444)
        #expect(try String(contentsOf: writable, encoding: .utf8) == "saved\n", "the checked folder's file got the save")
        #expect(try fm.destinationOfSymbolicLink(atPath: folderLink.path) == "bad")
        // The plain save through the retargeted folder link is refused.
        #expect(throws: ReadOnlyFileError.self) { try DocumentWrite.write(Data("x\n".utf8), to: url) }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n")
        // No temporary file is left in either folder.
        #expect(try fm.contentsOfDirectory(atPath: good.path) == ["doc.md"])
        #expect(try fm.contentsOfDirectory(atPath: bad.path) == ["doc.md"])
    }

    /// The write through the open folder keeps what an atomic save kept:
    /// the replaced file's mode, and a new file gets the usual one.
    @Test func aSaveKeepsTheFilesModeAndCreatesNewFiles() throws {
        let url = try file("kept.md", "before\n")
        defer { cleanUp(url) }
        #expect(chmod(url.path, 0o640) == 0)
        try DocumentWrite.write(Data("after\n".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "after\n")
        #expect(mode(url) == 0o640)
        let fresh = url.deletingLastPathComponent().appendingPathComponent("new.md")
        try DocumentWrite.write(Data("new\n".utf8), to: fresh)
        #expect(try String(contentsOf: fresh, encoding: .utf8) == "new\n")
        #expect(mode(fresh) & 0o600 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted() == ["kept.md", "new.md"])
    }

    /// A folder the user may write in but not read (0300) can't be opened
    /// for reading: the save opens it for search only and still checks
    /// and writes through it, refusing a read-only file.
    @Test func aFolderThatCantBeReadStillSavesAndRefusesReadOnlyFiles() throws {
        let url = try file("doc.md", "before\n")
        let dir = url.deletingLastPathComponent()
        let locked = dir.appendingPathComponent("locked.md")
        try Data("read-only\n".utf8).write(to: locked)
        #expect(chmod(locked.path, 0o444) == 0)
        defer { _ = chmod(dir.path, 0o755); cleanUp(url) }
        #expect(chmod(dir.path, 0o300) == 0)
        try DocumentWrite.write(Data("after\n".utf8), to: url)
        #expect(throws: ReadOnlyFileError.self) { try DocumentWrite.write(Data("x\n".utf8), to: locked) }
        #expect(chmod(dir.path, 0o755) == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == "after\n")
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n")
        #expect(mode(locked) == 0o444)
    }

    /// The 0300 folder's save, raced (Codex review round 2, 0.5.4): it
    /// checked and wrote by the folder's resolved path, so a folder on
    /// that path moved away and replaced by a link to a folder holding a
    /// read-only file of the same name, between the check and the write,
    /// had a writable file checked and the read-only one replaced (the
    /// rename needs only the folder's permission). The save now holds
    /// the checked folder open (search only) for the write.
    @Test func anUnreadableFolderReplacedByALinkAfterTheCheckStillWritesTheCheckedFolder() throws {
        let anchor = try file("anchor.md", "anchor\n")
        defer { cleanUp(anchor) }
        let base = anchor.deletingLastPathComponent()
        let fm = FileManager.default
        let good = base.appendingPathComponent("good"), moved = base.appendingPathComponent("moved")
        let bad = base.appendingPathComponent("bad")
        try fm.createDirectory(at: good, withIntermediateDirectories: false)
        try fm.createDirectory(at: bad, withIntermediateDirectories: false)
        defer {
            _ = chmod(good.path, 0o755); _ = chmod(moved.path, 0o755)
            cleanUp(moved.appendingPathComponent("doc.md")); cleanUp(bad.appendingPathComponent("doc.md"))
            try? fm.removeItem(at: good); try? fm.removeItem(at: moved)
        }
        let url = good.appendingPathComponent("doc.md"), locked = bad.appendingPathComponent("doc.md")
        try Data("writable\n".utf8).write(to: url)
        try Data("read-only\n".utf8).write(to: locked)
        #expect(chmod(locked.path, 0o444) == 0)
        #expect(chmod(good.path, 0o300) == 0)
        let probe = open(good.path, O_RDONLY | O_DIRECTORY)
        if probe >= 0 { close(probe) }
        #expect(probe == -1, "the folder can't be opened for reading")
        #expect(FileWriteAccess.blocked(at: url) == nil)

        try DocumentWrite.write(Data("saved\n".utf8), to: url, fileManager: .default) {
            // Between the check and the write: the checked folder moves
            // away and a link to the read-only file's folder takes its place.
            #expect(rename(good.path, moved.path) == 0)
            #expect(symlink("bad", good.path) == 0)
        }
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n", "the read-only file is untouched")
        #expect(mode(locked) == 0o444)
        #expect(try fm.destinationOfSymbolicLink(atPath: good.path) == "bad")
        #expect(chmod(moved.path, 0o755) == 0)
        #expect(try String(contentsOf: moved.appendingPathComponent("doc.md"), encoding: .utf8) == "saved\n",
                "the checked folder's file got the save")
        // No temporary file is left in either folder.
        #expect(try fm.contentsOfDirectory(atPath: moved.path) == ["doc.md"])
        #expect(try fm.contentsOfDirectory(atPath: bad.path) == ["doc.md"])
    }

    /// A writable file in a folder that doesn't allow new files (0555)
    /// saved in 0.5.3 (by path) and must still save (0.5.4 review round 2
    /// briefly failed it): the checked file is written in place through
    /// the open folder. A read-only file there is still refused, and a
    /// new file there still can't be created.
    @Test func aWritableFileInAFolderThatRefusesNewFilesStillSaves() throws {
        let url = try file("doc.md", "before\n")
        let dir = url.deletingLastPathComponent()
        let locked = dir.appendingPathComponent("locked.md")
        try Data("read-only\n".utf8).write(to: locked)
        #expect(chmod(locked.path, 0o444) == 0)
        #expect(chmod(url.path, 0o640) == 0)
        defer { _ = chmod(dir.path, 0o755); cleanUp(url) }
        #expect(chmod(dir.path, 0o555) == 0)
        let probe = open(dir.appendingPathComponent("probe").path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        if probe >= 0 { close(probe) }
        #expect(probe == -1, "the folder refuses a new file")

        try DocumentWrite.write(Data("after, and longer than before\n".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "after, and longer than before\n")
        try DocumentWrite.write(Data("short\n".utf8), to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "short\n", "the old bytes are truncated away")
        #expect(mode(url) == 0o640, "written in place, the file keeps its mode")
        #expect(throws: ReadOnlyFileError.self) { try DocumentWrite.write(Data("x\n".utf8), to: locked) }
        #expect(throws: CocoaError.self) { try DocumentWrite.write(Data("new\n".utf8), to: dir.appendingPathComponent("new.md")) }
        #expect(chmod(dir.path, 0o755) == 0)
        #expect(try String(contentsOf: locked, encoding: .utf8) == "read-only\n")
        #expect(mode(locked) == 0o444)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["doc.md", "locked.md"],
                "no temporary or new file is left")
    }

    /// The recovery copies named `name` left in the temporary folder.
    func recoveryCopies(named name: String) -> [String] {
        let tmp = NSTemporaryDirectory()
        let dirs = (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []
        return dirs.filter { $0.hasPrefix("owlink-recovery-") }
            .map { (tmp as NSString).appendingPathComponent($0) + "/" + name }
            .filter { FileManager.default.fileExists(atPath: $0) }
    }

    /// An in-place save whose write fails after part of the new text is on
    /// disk (injected EIO) puts the file back byte for byte from its
    /// recovery copy, longer and shorter, and deletes the copy. 0.5.4
    /// before QA truncated first; the round-1 fix restored from memory
    /// and ignored a failed restore.
    @Test func aWriteThatFailsAfterAPrefixIsPutBackFromTheRecoveryCopy() throws {
        let original = Data((0..<74_893).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let name = "doc-\(UUID().uuidString).md"
        let url = try file(name)
        let dir = url.deletingLastPathComponent()
        try original.write(to: url)
        defer { _ = chmod(dir.path, 0o755); cleanUp(url) }
        #expect(chmod(dir.path, 0o555) == 0)

        let longer = Data(repeating: UInt8(ascii: "n"), count: 200_000)
        let shorter = Data("short\n".utf8)
        for (data, after) in [(longer, 50_000), (longer, 100_000), (shorter, shorter.count)] {
            var thrown: Error?
            do {
                try DocumentWrite.write(data, to: url, fileManager: .default, afterCheck: nil,
                                        faults: .init(failWriteAfter: after))
            } catch { thrown = error }
            #expect(thrown is CocoaError, "the save fails with an error the user sees")
            #expect((thrown as NSError?)?.userInfo["OwlinkRecoveryCopy"] == nil)
            #expect(try Data(contentsOf: url) == original, "\(data.count) bytes failing after \(after): every original byte, and the length")
        }
        #expect(recoveryCopies(named: name).isEmpty, "the recovery copy is deleted once the file is back")
        #expect(chmod(dir.path, 0o755) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [name])

        // And a save that works leaves no copy either.
        #expect(chmod(dir.path, 0o555) == 0)
        try DocumentWrite.write(longer, to: url)
        #expect(try Data(contentsOf: url) == longer)
        #expect(recoveryCopies(named: name).isEmpty)
    }

    /// If putting the file back fails too, the recovery copy is kept and
    /// the error's recovery suggestion says where it is.
    @Test func aFailedRestoreKeepsTheRecoveryCopyAndSaysWhere() throws {
        let original = Data((0..<74_893).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ 1) })
        let name = "doc-\(UUID().uuidString).md"
        let url = try file(name)
        let dir = url.deletingLastPathComponent()
        try original.write(to: url)
        defer { _ = chmod(dir.path, 0o755); cleanUp(url) }
        #expect(chmod(dir.path, 0o555) == 0)

        var thrown: Error?
        do {
            try DocumentWrite.write(Data(repeating: 0x6E, count: 200_000), to: url, fileManager: .default, afterCheck: nil,
                                    faults: .init(failWriteAfter: 50_000, failRestore: true))
        } catch { thrown = error }
        let error = try #require(thrown as NSError?)
        let copy = try #require(error.userInfo["OwlinkRecoveryCopy"] as? String)
        defer { try? FileManager.default.removeItem(atPath: (copy as NSString).deletingLastPathComponent) }
        #expect(error.localizedRecoverySuggestion?.contains(copy) == true, "the alert shows where the copy is")
        #expect(copy.hasPrefix(NSTemporaryDirectory()) && copy.hasSuffix("/" + name))
        #expect(try Data(contentsOf: URL(fileURLWithPath: copy)) == original, "the copy is the file as it was")
        var st = stat()
        #expect(stat((copy as NSString).deletingLastPathComponent, &st) == 0 && st.st_mode & 0o777 == 0o700, "in a private folder")
        #expect(recoveryCopies(named: name) == [copy])
    }

    /// A file-size limit (RLIMIT_FSIZE) in a child process, since the
    /// limit and SIGXFSZ's disposition are process-wide. With the app's
    /// launch setup (`ignoreFileSizeSignal`), a save larger than the limit
    /// is refused before writing; one that hits the limit part way (the
    /// check skipped) gets EFBIG, not SIGXFSZ, and is put back. Either
    /// way the child lives and the file keeps every original byte. 0.5.4
    /// before QA truncated first: 74,893 bytes became the first 100,000
    /// of the new text.
    @Test func aFileSizeLimitInAChildProcessLeavesTheFileAsItWas() throws {
        if let path = ProcessInfo.processInfo.environment["OWLINK_FSIZE_CHILD"] {
            Self.fileSizeChild(URL(fileURLWithPath: path))
        }
        let original = Data((0..<74_893).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let url = try file("doc.md")
        let dir = url.deletingLastPathComponent()
        try original.write(to: url)
        defer { _ = chmod(dir.path, 0o755); cleanUp(url) }
        #expect(chmod(dir.path, 0o555) == 0)

        let args = CommandLine.arguments
        let bundle = try #require(args.firstIndex(of: "--test-bundle-path").map { args[$0 + 1] },
                                  "run by swiftpm-testing-helper: \(args)")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: args[0])
        child.arguments = ["--test-bundle-path", bundle, "--filter", "aFileSizeLimitInAChildProcessLeavesTheFileAsItWas",
                           bundle, "--testing-library", "swift-testing"]
        child.environment = ProcessInfo.processInfo.environment.merging(["OWLINK_FSIZE_CHILD": url.path]) { $1 }
        let out = Pipe()
        child.standardOutput = out
        child.standardError = out
        try child.run()
        let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        child.waitUntilExit()
        #expect(child.terminationReason == .exit, "not killed by a signal (SIGXFSZ): \(output)")
        #expect(child.terminationStatus == 0, "\(output)")
        #expect(output.contains("fsize child: ok"), "\(output)")
        #expect(try Data(contentsOf: url) == original, "the file keeps every original byte, and its length")
        #expect(chmod(dir.path, 0o755) == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["doc.md"])
    }

    /// The child's half: exits 0 printing "fsize child: ok", else 1.
    static func fileSizeChild(_ url: URL) -> Never {
        DocumentWrite.ignoreFileSizeSignal()
        var failures: [String] = []
        guard let original = try? Data(contentsOf: url) else { print("fsize child: can't read"); exit(1) }
        var limit = rlimit(rlim_cur: 100_000, rlim_max: 0)
        var old = rlimit()
        _ = getrlimit(RLIMIT_FSIZE, &old)
        limit.rlim_max = old.rlim_max
        guard setrlimit(RLIMIT_FSIZE, &limit) == 0 else { print("fsize child: can't lower RLIMIT_FSIZE"); exit(1) }
        let bigger = Data(repeating: UInt8(ascii: "n"), count: 200_000)
        for skip in [false, true] {
            do {
                try DocumentWrite.write(bigger, to: url, fileManager: .default, afterCheck: nil,
                                        faults: .init(skipSizeLimit: skip))
                failures.append("skip=\(skip): the save succeeded")
            } catch {
                let posix = ((error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError)?.code
                if posix != Int(EFBIG) { failures.append("skip=\(skip): \(error), not EFBIG") }
            }
            if (try? Data(contentsOf: url)) != original { failures.append("skip=\(skip): the file changed") }
        }
        print(failures.isEmpty ? "fsize child: ok" : "fsize child: \(failures)")
        exit(failures.isEmpty ? 0 : 1)
    }

    /// The in-place save is refused, before anything is written, when the
    /// volume has less room than the whole new text (`f_bavail` blocks of
    /// `f_bsize`), and an absurd report counts as room.
    @Test func theInPlaceSaveNeedsRoomForTheWholeText() {
        var fs = statfs()
        fs.f_bsize = 4096
        fs.f_bavail = 10
        #expect(DocumentWrite.enoughSpace(for: 40_960, in: fs))
        #expect(!DocumentWrite.enoughSpace(for: 40_961, in: fs))
        #expect(DocumentWrite.enoughSpace(for: 0, in: fs))
        fs.f_bavail = 0
        #expect(!DocumentWrite.enoughSpace(for: 1, in: fs))
        fs.f_bavail = .max
        fs.f_bsize = .max
        #expect(DocumentWrite.enoughSpace(for: .max, in: fs))
    }

    /// Folders that can't be opened for reading: 0300 (write and search)
    /// saves with the usual replace through a search-only handle, and
    /// 0100 (search only, so it also refuses new files) saves in place.
    /// Either way the file holds the new bytes and nothing else is left.
    @Test func aWritableFileInAnUnreadableFolderIsWritten() throws {
        for folderMode: mode_t in [0o300, 0o100] {
            let url = try file("doc.md", "before\n")
            let dir = url.deletingLastPathComponent()
            defer { _ = chmod(dir.path, 0o755); cleanUp(url) }
            #expect(chmod(dir.path, folderMode) == 0)
            let probe = open(dir.path, O_RDONLY | O_DIRECTORY)
            if probe >= 0 { close(probe) }
            #expect(probe == -1, "the \(String(folderMode, radix: 8)) folder can't be opened for reading")

            try DocumentWrite.write(Data("after\n".utf8), to: url)
            #expect(chmod(dir.path, 0o755) == 0)
            #expect(try String(contentsOf: url, encoding: .utf8) == "after\n", "the \(String(folderMode, radix: 8)) folder's file got the save")
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["doc.md"])
        }
    }

    /// The in-place save (folder refusing new files) is bound to the
    /// checked file: swapped between the check and the write for another
    /// writable file, a link, or a read-only file, the save fails with an
    /// error and neither file changes. The link points at the checked file
    /// itself (renamed to moved.md), so its target passes the device and
    /// inode match and only `O_NOFOLLOW` refuses it.
    @Test func theInPlaceSaveCantBeRedirectedToAnotherFile() throws {
        enum Swap: CaseIterable { case otherFile, link, readOnly }
        for swap in Swap.allCases {
            let url = try file("doc.md", "checked\n")
            let dir = url.deletingLastPathComponent()
            let fm = FileManager.default
            let moved = dir.appendingPathComponent("moved.md"), other = dir.appendingPathComponent("other.md")
            try Data("other\n".utf8).write(to: other)
            defer { _ = chmod(dir.path, 0o755); cleanUp(url) }
            #expect(chmod(dir.path, 0o555) == 0)

            #expect(throws: CocoaError.self) {
                try DocumentWrite.write(Data("saved\n".utf8), to: url, fileManager: .default) {
                    // Between the check and the write: another file takes the checked file's name.
                    #expect(chmod(dir.path, 0o755) == 0)
                    #expect(rename(url.path, moved.path) == 0)
                    switch swap {
                    case .otherFile:
                        #expect(rename(other.path, url.path) == 0)
                    case .link:
                        #expect(symlink("moved.md", url.path) == 0)
                    case .readOnly:
                        #expect((try? Data("read-only\n".utf8).write(to: url)) != nil)
                        #expect(chmod(url.path, 0o444) == 0)
                    }
                    #expect(chmod(dir.path, 0o555) == 0)
                }
            }
            #expect(chmod(dir.path, 0o755) == 0)
            #expect(try String(contentsOf: moved, encoding: .utf8) == "checked\n", "\(swap): the checked file is untouched")
            switch swap {
            case .otherFile:
                #expect(try String(contentsOf: url, encoding: .utf8) == "other\n", "the other writable file is untouched")
            case .link:
                #expect(try fm.destinationOfSymbolicLink(atPath: url.path) == "moved.md", "the link stays a link")
                #expect(try String(contentsOf: other, encoding: .utf8) == "other\n", "the other file is untouched")
            case .readOnly:
                #expect(try String(contentsOf: url, encoding: .utf8) == "read-only\n", "the read-only file is untouched")
                #expect(mode(url) == 0o444)
            }
            #expect(try fm.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".owlink-save-") })
        }
    }

    /// A FIFO (no reader) takes the checked file's name between the check
    /// and the write. In a folder refusing new files the in-place save
    /// fails with an error; in a writable one the usual replace renames
    /// the new file over the name. Neither blocks on opening the FIFO
    /// (opened without `O_NONBLOCK`, it waits for a reader forever), the
    /// checked file keeps its bytes, and no other file changes. The save
    /// runs on its own thread with a bound, and a stuck one is released
    /// by opening the FIFO, so a hang fails the test instead of the suite.
    @Test func aFIFOInTheCheckedFilesPlaceDoesntHangTheSave() throws {
        final class Outcome: @unchecked Sendable {
            var swapped = false, error: Error?
        }
        for folderMode: mode_t in [0o555, 0o755] {
            let url = try file("doc.md", "checked\n")
            let dir = url.deletingLastPathComponent()
            let moved = dir.appendingPathComponent("moved.md"), other = dir.appendingPathComponent("other.md")
            try Data("other\n".utf8).write(to: other)
            defer { _ = chmod(dir.path, 0o755); cleanUp(url) }
            #expect(chmod(dir.path, folderMode) == 0)

            let outcome = Outcome()
            let done = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                do {
                    try DocumentWrite.write(Data("saved\n".utf8), to: url, fileManager: .default) {
                        // Between the check and the write: a FIFO takes the checked file's name.
                        outcome.swapped = chmod(dir.path, 0o755) == 0
                            && rename(url.path, moved.path) == 0
                            && mkfifo(url.path, 0o666) == 0
                            && chmod(dir.path, folderMode) == 0
                    }
                } catch {
                    outcome.error = error
                }
                done.signal()
            }
            let finished = done.wait(timeout: .now() + 20) == .success
            if !finished {
                // Stuck opening the FIFO: give it the other end so the save returns.
                let release = open(url.path, O_RDWR | O_NONBLOCK)
                let released = done.wait(timeout: .now() + 20) == .success
                if release >= 0 { close(release) }
                // Still running: its outcome and the folder aren't safe to read.
                try #require(released, "the \(String(folderMode, radix: 8)) folder's save returns once the FIFO has a reader")
            }
            let label = String(folderMode, radix: 8)
            #expect(finished, "the \(label) folder's save doesn't block on the FIFO")
            #expect(outcome.swapped, "the FIFO took the checked file's name")
            #expect(chmod(dir.path, 0o755) == 0)
            #expect(try String(contentsOf: moved, encoding: .utf8) == "checked\n", "\(label): the checked file is untouched")
            #expect(try String(contentsOf: other, encoding: .utf8) == "other\n", "\(label): the other file is untouched")
            var st = stat()
            let statted = lstat(url.path, &st) == 0
            #expect(statted)
            if folderMode == 0o555 {
                #expect(outcome.error is CocoaError, "in place: the save fails with an error")
                #expect(st.st_mode & S_IFMT == S_IFIFO, "the FIFO is left as it was")
            } else {
                #expect(outcome.error == nil, "a writable folder still saves with the usual replace")
                // Reading a FIFO left in place would block the test itself.
                try #require(statted)
                try #require(st.st_mode & S_IFMT == S_IFREG)
                #expect(try String(contentsOf: url, encoding: .utf8) == "saved\n")
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == ["doc.md", "moved.md", "other.md"],
                    "\(label): no temporary file is left")
        }
    }

    @Test func applyIsReadOnlyForAnUnwritableFile() throws {
        let url = try file()
        defer { cleanUp(url) }
        let text = try String(contentsOf: url, encoding: .utf8)
        let snap = OwlDocumentSnapshot(text: text, generation: 2, fileName: "readonly.md", language: "markdown")
        let p = try OwlEditProposal.anchored(find: "Try editing it.", replace: "Editing this file is not permitted.", in: snap).get()
        func readOnly() -> Bool {
            // An editable buffer (Allow Editing chosen), not following, not large: only the file decides.
            OwlEditAccess.readOnly(editable: true, following: false, largeDocument: false, extrasPaused: false,
                                   unwritableFile: FileWriteAccess.blocked(at: url) != nil)
        }
        #expect(!readOnly())
        #expect(p.state(text: text as NSString, generation: 2, readOnly: readOnly()) == .ready((text as NSString).range(of: "Try editing it.")))
        #expect(chmod(url.path, 0o444) == 0)
        #expect(readOnly())
        #expect(p.state(text: text as NSString, generation: 2, readOnly: readOnly()) == .readOnly)
        let refreshed = OwlEditProposal.refresh([p], text: text as NSString, generation: 2, readOnly: readOnly())
        #expect(refreshed.states == [.readOnly] && refreshed.searches == 0)
        // Writable again: Apply comes back.
        #expect(chmod(url.path, 0o644) == 0)
        #expect(!readOnly())
    }

    @Test func theNoticeAndTitleSayWhy() {
        #expect(FileWriteAccess.notice(.permissions, name: "a.md").contains("permission"))
        #expect(FileWriteAccess.notice(.locked, name: "a.md").contains("locked"))
        #expect(FileWriteAccess.notice(.readOnlyVolume, name: "a.md").contains("read-only volume"))
        #expect(FileWriteAccess.windowTitle("a.md", readOnly: false) == "a.md")
        #expect(FileWriteAccess.windowTitle("a.md", readOnly: true) == "a.md — Read-Only")
        #expect(EditedIndicator.windowTitle(displayName: FileWriteAccess.windowTitle("a.md", readOnly: true), isDirty: true)
                == "a.md — Read-Only •", "the unsaved mark stays last")
    }
}
