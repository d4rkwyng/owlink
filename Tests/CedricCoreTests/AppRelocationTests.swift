import Darwin
import Foundation
import Testing
@testable import CedricCore

/// Move to Applications (AppRelocation.swift): where the app is running
/// from, what the move plans to do, and the copy / quarantine / replace
/// steps with each one made to fail. The quarantine removal must only ever
/// touch the staging copy the mover wrote.
@Suite struct AppLocationTests {
    static let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)
    static let folders = AppLocation.applicationsFolders(home: home)

    static func classify(_ path: String, translocated: Bool? = false, original: String? = nil,
                         readOnly: Bool = false, quarantined: Bool = false) -> AppLocation {
        AppLocation.classify(bundle: URL(fileURLWithPath: path), translocated: translocated,
                             original: original.map { URL(fileURLWithPath: $0) },
                             applicationsFolders: folders, onReadOnlyVolume: readOnly, quarantined: quarantined)
    }

    static let translocatedPath = "/private/var/folders/xy/abc/T/AppTranslocation/6E1B9C2A-0000-4000-8000-000000000000/d/Owlink.app"

    @Test func aTranslocatedPathIsTranslocatedEvenWhenItsOriginalIsInApplications() {
        let l = Self.classify(Self.translocatedPath, translocated: true, original: "/Applications/Owlink.app")
        #expect(l == .translocated(original: URL(fileURLWithPath: "/Applications/Owlink.app")))
        #expect(l.offersMove)
    }

    @Test func withoutSecurityFrameworkTheAppTranslocationPathDecides() {
        #expect(Self.classify(Self.translocatedPath, translocated: nil) == .translocated(original: nil))
        #expect(Self.classify("/Applications/Owlink.app", translocated: nil) == .applications)
    }

    @Test func securityFrameworkWinsOverThePath() {
        // Security said no: a folder that happens to be named like it isn't translocation.
        #expect(Self.classify("/Users/tester/AppTranslocation/x/Owlink.app", translocated: false) == .elsewhere(quarantined: false))
    }

    @Test func applicationsFoldersAreFine() {
        for p in ["/Applications/Owlink.app", "/Applications/Utilities/Owlink.app", "/Users/tester/Applications/Owlink.app"] {
            let l = Self.classify(p, quarantined: true)
            #expect(l == .applications, "\(p)")
            #expect(!l.offersMove)
        }
    }

    @Test func aLookalikeFolderIsNotApplications() {
        #expect(Self.classify("/Applications2/Owlink.app", quarantined: true) == .elsewhere(quarantined: true))
        #expect(Self.classify("/Users/tester/ApplicationsOld/Owlink.app") == .elsewhere(quarantined: false))
        // The folder itself isn't "inside" it.
        #expect(!AppLocation.isInside(URL(fileURLWithPath: "/Applications"), anyOf: Self.folders))
    }

    @Test func aReadOnlyVolumeIsADiskImage() {
        let l = Self.classify("/Volumes/Owlink/Owlink.app", readOnly: true)
        #expect(l == .diskImage)
        #expect(l.offersMove)
        // A writable external drive is just somewhere else.
        #expect(Self.classify("/Volumes/External/Owlink.app", readOnly: false) == .elsewhere(quarantined: false))
    }

    @Test func aDownloadOutsideApplicationsIsOfferedTheMoveAndADeveloperBuildIsNot() {
        for p in ["/Users/tester/Downloads/Owlink.app", "/Users/tester/Desktop/Owlink.app"] {
            #expect(Self.classify(p, quarantined: true).offersMove, "\(p)")
        }
        #expect(!Self.classify("/Users/tester/GitHub/owlink/dist/Owlink.app", quarantined: false).offersMove)
    }

    @Test func theRunningTestBundleIsNotTranslocated() {
        // Security.framework's answer for a real, non-translocated path.
        #expect(Translocation.isTranslocated(Bundle.main.bundleURL) == false)
    }

    @Test func theRelaunchCommandPassesThePathAsAnArgument() {
        let app = URL(fileURLWithPath: "/Applications/Owl link\"$(x).app")
        let c = AppMover.relaunchCommand(pid: 4242, app: app)
        #expect(c[0] == "/bin/sh" && c[1] == "-c" && c[3] == "sh")
        #expect(c[4] == "4242" && c[5] == app.path)
        #expect(!c[2].contains(app.path))
    }
}

/// A file system in memory that records every call and can fail any one.
final class FakeInstallFS: AppInstallFileSystem, @unchecked Sendable {
    var items: Set<String>
    var writable: Set<String>
    var readOnly: Set<String> = []
    var badSignature = false
    var fail: Set<String> = []   // "copy", "rename", "trash:<path>", "quarantine", "create"
    var log: [String] = []
    var quarantineRemovedUnder: [String] = []
    var trashed: [String] = []

    init(items: Set<String>, writable: Set<String>) {
        self.items = items
        self.writable = writable
    }

    struct Boom: Error {}
    func exists(_ url: URL) -> Bool { items.contains(url.path) }
    func isWritableFolder(_ url: URL) -> Bool { items.contains(url.path) && writable.contains(url.path) }
    func createFolder(_ url: URL) throws {
        log.append("mkdir \(url.path)")
        if fail.contains("create") { throw Boom() }
        items.insert(url.path); writable.insert(url.path)
    }
    func copy(_ from: URL, to: URL) throws {
        log.append("copy \(from.path) -> \(to.path)")
        if fail.contains("copy") { items.insert(to.path); throw Boom() }   // a partial copy is left
        items.insert(to.path)
    }
    func rename(_ from: URL, to: URL) throws {
        log.append("rename \(from.path) -> \(to.path)")
        if fail.contains("rename") && from.lastPathComponent.hasPrefix(".Owlink-moving") { throw Boom() }
        items.remove(from.path); items.insert(to.path)
    }
    func remove(_ url: URL) throws { log.append("rm \(url.path)"); items.remove(url.path) }
    func trash(_ url: URL) throws -> URL? {
        log.append("trash \(url.path)")
        if fail.contains("trash:\(url.path)") { throw Boom() }
        items.remove(url.path); trashed.append(url.path)
        let t = "/Users/tester/.Trash/\(url.lastPathComponent)"
        items.insert(t)
        return URL(fileURLWithPath: t)
    }
    func removeQuarantine(under url: URL) throws {
        log.append("unquarantine \(url.path)")
        quarantineRemovedUnder.append(url.path)
        if fail.contains("quarantine") { throw Boom() }
    }
    func signatureIsValid(_ url: URL) -> Bool { !badSignature }
    func isReadOnlyVolume(_ url: URL) -> Bool { readOnly.contains { url.path.hasPrefix($0) } }
}

@Suite struct AppMoverTests {
    static let apps = "/Applications"
    static let dest = "/Applications/Owlink.app"
    static let staging = "/Applications/.Owlink-moving-TEST.app"
    static let folders = AppLocation.applicationsFolders(home: URL(fileURLWithPath: "/Users/tester"))
    static let download = "/Users/tester/Downloads/Owlink.app"
    static let translocated = AppLocationTests.translocatedPath

    static func mover(_ fs: FakeInstallFS) -> AppMover { AppMover(fs: fs, makeStagingName: { ".Owlink-moving-TEST.app" }) }

    static func plan(_ location: AppLocation, source: String, fs: FakeInstallFS) throws -> AppMovePlan {
        try AppMovePlan.make(location: location, source: URL(fileURLWithPath: source), folders: folders, fs: fs)
    }

    /// Every path the fake saw quarantine removed under is the staging copy.
    static func onlyStagingUnquarantined(_ fs: FakeInstallFS) -> Bool {
        fs.quarantineRemovedUnder.allSatisfy { $0 == staging }
    }

    @Test func aDownloadIsCopiedUnquarantinedRenamedAndTheOriginalTrashed() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(p.destination.path == Self.dest && !p.destinationExists && p.trashOriginal)
        let out = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(out == .init(installed: URL(fileURLWithPath: Self.dest), originalLeftBehind: nil))
        #expect(fs.log == [
            "copy \(Self.download) -> \(Self.staging)",
            "unquarantine \(Self.staging)",
            "rename \(Self.staging) -> \(Self.dest)",
            "trash \(Self.download)",
        ])
        #expect(Self.onlyStagingUnquarantined(fs))
    }

    @Test func translocatedFromApplicationsReplacesItsOwnOriginalWithoutAsking() throws {
        // 0.6.0 QA's case: moved into /Applications by a script, still translocated.
        let fs = FakeInstallFS(items: [Self.apps, Self.dest, Self.translocated], writable: [Self.apps])
        let loc = AppLocation.translocated(original: URL(fileURLWithPath: Self.dest))
        let p = try Self.plan(loc, source: Self.translocated, fs: fs)
        #expect(p.destinationExists && p.destinationIsOriginal && !p.trashOriginal)
        _ = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(fs.log == [
            "copy \(Self.translocated) -> \(Self.staging)",
            "unquarantine \(Self.staging)",
            "trash \(Self.dest)",
            "rename \(Self.staging) -> \(Self.dest)",
        ])
        #expect(fs.trashed == [Self.dest])
        #expect(Self.onlyStagingUnquarantined(fs))
    }

    @Test func translocatedFromDownloadsTrashesTheRealOriginalNotTheTranslocatedPath() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download, Self.translocated], writable: [Self.apps])
        let p = try Self.plan(.translocated(original: URL(fileURLWithPath: Self.download)), source: Self.translocated, fs: fs)
        _ = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(fs.trashed == [Self.download])
        #expect(fs.log.first == "copy \(Self.translocated) -> \(Self.staging)")
        #expect(Self.onlyStagingUnquarantined(fs))
    }

    @Test func translocatedWithAnUnknownOriginalTrashesNothingButTheReplacedDestination() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.translocated], writable: [Self.apps])
        let p = try Self.plan(.translocated(original: nil), source: Self.translocated, fs: fs)
        #expect(!p.trashOriginal)
        _ = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(fs.trashed.isEmpty)
    }

    @Test func aDiskImageIsCopiedAndNeverTrashed() throws {
        let src = "/Volumes/Owlink/Owlink.app"
        let fs = FakeInstallFS(items: [Self.apps, src], writable: [Self.apps])
        fs.readOnly = ["/Volumes/Owlink"]
        let p = try Self.plan(.diskImage, source: src, fs: fs)
        #expect(!p.trashOriginal)
        _ = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(fs.trashed.isEmpty)
        #expect(fs.items.contains(src))
        #expect(Self.onlyStagingUnquarantined(fs))
    }

    @Test func anotherOwlinkInApplicationsNeedsTheUsersYes() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.dest, Self.download], writable: [Self.apps])
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(p.destinationExists && !p.destinationIsOriginal)
        #expect(throws: AppMoveError.destinationExists(URL(fileURLWithPath: Self.dest))) {
            try Self.mover(fs).install(p, replaceExisting: false)
        }
        #expect(fs.log.isEmpty)   // nothing written, nothing unquarantined
        // With the user's yes it goes to the Trash (not deleted) and is replaced.
        _ = try Self.mover(fs).install(p, replaceExisting: true)
        #expect(fs.trashed == [Self.dest, Self.download])
        #expect(!fs.log.contains { $0.hasPrefix("rm \(Self.dest)") })
    }

    @Test func aFailedCopyRemovesThePartialStagingCopyAndTouchesNothingElse() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        fs.fail = ["copy"]
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(throws: AppMoveError.self) { try Self.mover(fs).install(p, replaceExisting: false) }
        #expect(fs.log == ["copy \(Self.download) -> \(Self.staging)", "rm \(Self.staging)"])
        #expect(fs.quarantineRemovedUnder.isEmpty)
        #expect(fs.items == [Self.apps, Self.download])
    }

    @Test func aBrokenSignatureOnTheCopyStopsBeforeQuarantineIsTouched() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        fs.badSignature = true
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(throws: AppMoveError.signatureInvalid) { try Self.mover(fs).install(p, replaceExisting: false) }
        #expect(fs.quarantineRemovedUnder.isEmpty)
        #expect(!fs.items.contains(Self.staging) && !fs.items.contains(Self.dest))
    }

    @Test func aFailedQuarantineRemovalDropsTheCopy() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        fs.fail = ["quarantine"]
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(throws: AppMoveError.self) { try Self.mover(fs).install(p, replaceExisting: false) }
        #expect(!fs.items.contains(Self.staging) && !fs.items.contains(Self.dest))
        #expect(fs.trashed.isEmpty)
        #expect(Self.onlyStagingUnquarantined(fs))
    }

    @Test func anExistingAppThatWontGoToTheTrashStaysAndTheCopyGoes() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.dest, Self.download], writable: [Self.apps])
        fs.fail = ["trash:\(Self.dest)"]
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(throws: AppMoveError.self) { try Self.mover(fs).install(p, replaceExisting: true) }
        #expect(fs.items == [Self.apps, Self.dest, Self.download])
    }

    @Test func aFailedRenameDropsTheCopy() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        fs.fail = ["rename"]
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(throws: AppMoveError.self) { try Self.mover(fs).install(p, replaceExisting: false) }
        #expect(fs.items == [Self.apps, Self.download])
    }

    @Test func aFailedRenameAfterReplacingPutsTheOldAppBackFromTheTrash() throws {
        // The translocated-from-Applications case: the user's only copy must survive.
        let fs = FakeInstallFS(items: [Self.apps, Self.dest, Self.translocated], writable: [Self.apps])
        fs.fail = ["rename"]
        let p = try Self.plan(.translocated(original: URL(fileURLWithPath: Self.dest)), source: Self.translocated, fs: fs)
        #expect(throws: AppMoveError.self) { try Self.mover(fs).install(p, replaceExisting: false) }
        #expect(fs.log.suffix(3) == [
            "rename \(Self.staging) -> \(Self.dest)",
            "rm \(Self.staging)",
            "rename /Users/tester/.Trash/Owlink.app -> \(Self.dest)",
        ])
    }

    @Test func aDestinationThatAppearedAfterThePlanIsNotReplacedWithoutAsking() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(!p.destinationExists)
        fs.items.insert(Self.dest)   // dropped in while the question was up
        #expect(throws: AppMoveError.destinationExists(URL(fileURLWithPath: Self.dest))) {
            try Self.mover(fs).install(p, replaceExisting: false)
        }
        #expect(fs.trashed.isEmpty)
        #expect(!fs.items.contains(Self.staging))
    }

    @Test func anOriginalThatWontGoToTheTrashIsReportedButTheInstallStands() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        fs.fail = ["trash:\(Self.download)"]
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        let out = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(out.originalLeftBehind?.path == Self.download)
        #expect(fs.items.contains(Self.dest))
    }

    @Test func aStandardUserGetsHomeApplicationsCreatedWhenMissing() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [])
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(p.destination.path == "/Users/tester/Applications/Owlink.app")
        _ = try AppMover(fs: fs, makeStagingName: { "s.app" }).install(p, replaceExisting: false)
        #expect(fs.log.first == "mkdir /Users/tester/Applications")
        #expect(fs.quarantineRemovedUnder == ["/Users/tester/Applications/s.app"])
    }

    @Test func noWritableApplicationsFolderAtAll() {
        let fs = FakeInstallFS(items: [Self.apps, "/Users/tester/Applications", Self.download], writable: [])
        #expect(throws: AppMoveError.noWritableApplicationsFolder) {
            try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        }
    }
}

/// The real quarantine removal on real files in a temp folder: it clears
/// the copy and leaves a sibling "source" with its attribute.
@Suite struct QuarantineOnDiskTests {
    static func setQ(_ url: URL) {
        let v = "0081;\(String(Int(Date().timeIntervalSince1970), radix: 16));Safari;"
        _ = url.withUnsafeFileSystemRepresentation { p in
            v.withCString { setxattr(p!, Quarantine.name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        }
    }

    @Test func removalClearsEveryFileInTheCopyAndNotTheSource() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("owlink-q-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let src = tmp.appendingPathComponent("src/Owlink.app")
        let inner = src.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: inner.appendingPathComponent("Cedric"))
        try FileManager.default.createSymbolicLink(at: src.appendingPathComponent("Contents/link"), withDestinationURL: inner)
        for u in [src, src.appendingPathComponent("Contents"), inner, inner.appendingPathComponent("Cedric")] { Self.setQ(u) }
        #expect(Quarantine.has(src))

        let copy = tmp.appendingPathComponent("Applications/Owlink.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LiveAppInstallFileSystem().copy(src, to: copy)
        #expect(Quarantine.has(copy.appendingPathComponent("Contents/MacOS/Cedric")))   // copied with it

        try Quarantine.removeRecursively(under: copy)
        for rel in ["", "Contents", "Contents/MacOS", "Contents/MacOS/Cedric"] {
            #expect(!Quarantine.has(rel.isEmpty ? copy : copy.appendingPathComponent(rel)), "copy/\(rel)")
            #expect(Quarantine.has(rel.isEmpty ? src : src.appendingPathComponent(rel)), "src/\(rel)")
        }
        // A file that never had it is not an error.
        try Quarantine.removeRecursively(under: copy)
    }
}

/// The live copy keeps a signed bundle's signature valid (what the mover
/// checks before it removes any quarantine), and a bundle with an edited
/// file or no signature fails the check. The bundle is a tiny one made
/// here and signed ad hoc with /usr/bin/codesign.
@Suite struct CodeSignatureOnDiskTests {
    static func makeSignedApp(at app: URL) throws {
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: macos.appendingPathComponent("Tiny"))
        let info: [String: Any] = ["CFBundleIdentifier": "invalid.owlink.test.tiny", "CFBundleExecutable": "Tiny",
                                   "CFBundlePackageType": "APPL", "CFBundleName": "Tiny"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", app.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
    }

    @Test func aCopiedSignedAppStaysValidAndATamperedOneDoesNot() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("owlink-sig-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let app = tmp.appendingPathComponent("src/Tiny.app")
        try Self.makeSignedApp(at: app)
        #expect(CodeSignature.isValid(app))
        let copy = tmp.appendingPathComponent("Applications/Tiny.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LiveAppInstallFileSystem().copy(app, to: copy)
        #expect(CodeSignature.isValid(copy))
        let plist = copy.appendingPathComponent("Contents/Info.plist")
        var d = try Data(contentsOf: plist); d.append(contentsOf: Array("\n".utf8))
        try FileManager.default.removeItem(at: plist)
        try d.write(to: plist)
        #expect(!CodeSignature.isValid(copy))
        #expect(CodeSignature.isValid(app))
        let junk = tmp.appendingPathComponent("Junk.app/Contents")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        #expect(!CodeSignature.isValid(junk.deletingLastPathComponent()))
    }
}
