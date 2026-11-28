import Darwin
import Foundation
import Security
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
        AppLocation.classify(bundle: URL(fileURLWithPath: path, isDirectory: true), translocated: translocated,
                             original: original.map { URL(fileURLWithPath: $0, isDirectory: true) },
                             applicationsFolders: folders, onReadOnlyVolume: readOnly, quarantined: quarantined)
    }

    static let translocatedPath = "/private/var/folders/xy/abc/T/AppTranslocation/6E1B9C2A-0000-4000-8000-000000000000/d/Owlink.app"

    @Test func aTranslocatedPathIsTranslocatedEvenWhenItsOriginalIsInApplications() {
        let l = Self.classify(Self.translocatedPath, translocated: true, original: "/Applications/Owlink.app")
        #expect(l == .translocated(original: URL(fileURLWithPath: "/Applications/Owlink.app", isDirectory: true)))
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
        #expect(!AppLocation.isInside(URL(fileURLWithPath: "/Applications", isDirectory: true), anyOf: Self.folders))
    }

    @Test func aReadOnlyVolumeIsADiskImage() {
        let l = Self.classify("/Volumes/Owlink/Owlink.app", readOnly: true)
        #expect(l == .diskImage)
        #expect(l.offersMove)
        // A writable external drive is just somewhere else.
        #expect(Self.classify("/Volumes/External/Owlink.app", readOnly: false) == .elsewhere(quarantined: false))
    }

    @Test func everyCopyOutsideApplicationsIsOfferedTheMoveQuarantinedOrNot() {
        for p in ["/Users/tester/Downloads/Owlink.app", "/Users/tester/Desktop/Owlink.app"] {
            #expect(Self.classify(p, quarantined: true).offersMove, "\(p)")
            // Unpacked with a tool that drops the quarantine: still a release copy outside Applications.
            #expect(Self.classify(p, quarantined: false).offersMove, "\(p)")
        }
    }

    @Test func onlyAReleaseBundleOutsideApplicationsIsAsked() {
        let app = URL(fileURLWithPath: "/Users/tester/Downloads/Owlink.app")
        let loc = Self.classify(app.path, quarantined: false)
        #expect(AppLocation.shouldOffer(loc, bundle: app, checksEnabled: false, suppressed: false))
        // A check or debug build (dist/, .build), "Don't ask again", `swift run`, Applications.
        #expect(!AppLocation.shouldOffer(loc, bundle: app, checksEnabled: true, suppressed: false))
        #expect(!AppLocation.shouldOffer(loc, bundle: app, checksEnabled: false, suppressed: true))
        let bare = URL(fileURLWithPath: "/Users/tester/GitHub/owlink/.build/debug")
        #expect(!AppLocation.shouldOffer(Self.classify(bare.path), bundle: bare, checksEnabled: false, suppressed: false))
        let installed = URL(fileURLWithPath: "/Applications/Owlink.app", isDirectory: true)
        #expect(!AppLocation.shouldOffer(Self.classify(installed.path), bundle: installed, checksEnabled: false, suppressed: false))
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
/// Every item has an identity (a fresh number whenever something new is
/// written at a path) and a signer ("owlink": the running app's), so the
/// tests can tell "the app the user was asked about" from "whatever is at
/// that path now", and a copy of something else from the running app.
final class FakeInstallFS: AppInstallFileSystem, @unchecked Sendable {
    /// path → which item is there.
    var ids: [String: Int] = [:]
    /// path → who signed the item there.
    var signer: [String: String] = [:]
    var runningSigner = "owlink"
    var writable: Set<String>
    var readOnly: Set<String> = []
    var fail: Set<String> = []   // "copy", "rename", "swap", "trash:<path>", "quarantine", "create"
    var log: [String] = []
    var quarantineRemovedUnder: [String] = []
    var trashed: [String] = []
    /// Item identities that went to the Trash, in order.
    var trashedIDs: [Int] = []
    /// Paths that must never be empty during the install (the installed
    /// app: a crash at any step must not leave it only in the Trash).
    var watch: Set<String> = []
    var wentMissing: Set<String> = []
    /// Runs inside `swap`, just before it exchanges (a race with Finder).
    var beforeSwap: ((FakeInstallFS) -> Void)?
    /// The identity the last copy got.
    var lastCopyID: Int?
    private var nextID = 1

    var items: Set<String> {
        get { Set(ids.keys) }
        set {
            for k in ids.keys where !newValue.contains(k) { ids[k] = nil; signer[k] = nil }
            for k in newValue where ids[k] == nil { ids[k] = fresh(); signer[k] = runningSigner }
        }
    }

    init(items: Set<String>, writable: Set<String>) {
        self.writable = writable
        self.items = items
    }

    func fresh() -> Int { defer { nextID += 1 }; return nextID }
    /// A different item is put at `path` (Finder replacing it).
    @discardableResult func replace(_ path: String, signer s: String = "owlink") -> Int {
        let id = fresh(); ids[path] = id; signer[path] = s
        return id
    }
    private func move(_ from: String, _ to: String) {
        ids[to] = ids[from]; signer[to] = signer[from]
        ids[from] = nil; signer[from] = nil
        noteMissing()
    }
    private func noteMissing() { for w in watch where ids[w] == nil { wentMissing.insert(w) } }

    struct Boom: Error {}
    func exists(_ url: URL) -> Bool { ids[url.path] != nil }
    func identity(_ url: URL) -> FileIdentity? { ids[url.path].map { FileIdentity(device: 1, inode: UInt64($0)) } }
    func isWritableFolder(_ url: URL) -> Bool { exists(url) && writable.contains(url.path) }
    func createFolder(_ url: URL) throws {
        log.append("mkdir \(url.path)")
        if fail.contains("create") { throw Boom() }
        items.insert(url.path); writable.insert(url.path)
    }
    func copy(_ from: URL, to: URL) throws {
        log.append("copy \(from.path) -> \(to.path)")
        let id = fresh()
        ids[to.path] = id; signer[to.path] = signer[from.path]
        lastCopyID = id
        if fail.contains("copy") { throw Boom() }   // a partial copy is left
    }
    func renameExclusive(_ from: URL, to: URL) throws {
        log.append("rename \(from.path) -> \(to.path)")
        if fail.contains("rename") || exists(to) || !exists(from) { throw Boom() }
        move(from.path, to.path)
    }
    func swap(_ a: URL, _ b: URL) throws {
        log.append("swap \(a.path) <-> \(b.path)")
        beforeSwap?(self)
        if fail.contains("swap") || !exists(a) || !exists(b) { throw Boom() }
        (ids[a.path], ids[b.path]) = (ids[b.path], ids[a.path])
        (signer[a.path], signer[b.path]) = (signer[b.path], signer[a.path])
    }
    func remove(_ url: URL) throws { log.append("rm \(url.path)"); ids[url.path] = nil; signer[url.path] = nil; noteMissing() }
    func trash(_ url: URL) throws -> URL? {
        log.append("trash \(url.path)")
        if fail.contains("trash:\(url.path)") || !exists(url) { throw Boom() }
        trashed.append(url.path)
        trashedIDs.append(ids[url.path]!)
        let t = "/Users/tester/.Trash/\(trashed.count)-\(url.lastPathComponent)"
        move(url.path, t)
        return URL(fileURLWithPath: t)
    }
    func removeQuarantine(under url: URL) throws {
        log.append("unquarantine \(url.path)")
        quarantineRemovedUnder.append(url.path)
        if fail.contains("quarantine") { throw Boom() }
    }
    func signatureMatchesRunningApp(_ url: URL) -> Bool { signer[url.path] == runningSigner }
    func isReadOnlyVolume(_ url: URL) -> Bool { readOnly.contains { url.path.hasPrefix($0) } }
}

@Suite struct AppMoverTests {
    /// Every path here is a folder or a bundle. Built as a directory URL, as
    /// the mover builds its destination (appendingPathComponent(_:isDirectory:
    /// true)), without looking at the disk: URL(fileURLWithPath:) alone adds
    /// the trailing slash only when the path exists as a folder on this Mac,
    /// so a real /Applications/Owlink.app would change what the tests expect.
    static func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    static let apps = "/Applications"
    static let dest = "/Applications/Owlink.app"
    static let staging = "/Applications/.Owlink-moving-TEST.app"
    static let folders = AppLocation.applicationsFolders(home: Self.url("/Users/tester"))
    static let download = "/Users/tester/Downloads/Owlink.app"
    static let translocated = AppLocationTests.translocatedPath

    static func mover(_ fs: FakeInstallFS) -> AppMover { AppMover(fs: fs, makeStagingName: { ".Owlink-moving-TEST.app" }) }

    static func plan(_ location: AppLocation, source: String, fs: FakeInstallFS) throws -> AppMovePlan {
        try AppMovePlan.make(location: location, source: Self.url(source), folders: folders, fs: fs)
    }

    /// Every path the fake saw quarantine removed under is the staging copy.
    static func onlyStagingUnquarantined(_ fs: FakeInstallFS) -> Bool {
        fs.quarantineRemovedUnder.allSatisfy { $0 == staging }
    }

    /// 0.6.0 QA's case: moved into /Applications by a script, still translocated.
    static func translocatedFromApplications() throws -> (FakeInstallFS, AppMovePlan) {
        let fs = FakeInstallFS(items: [Self.apps, Self.dest, Self.translocated], writable: [Self.apps])
        fs.watch = [Self.dest]
        let p = try Self.plan(.translocated(original: Self.url(Self.dest)), source: Self.translocated, fs: fs)
        return (fs, p)
    }

    @Test func aDownloadIsCopiedUnquarantinedRenamedAndTheOriginalTrashed() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(p.destination.path == Self.dest && !p.destinationExists && p.trashOriginal)
        let out = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(out == .init(installed: Self.url(Self.dest)))
        #expect(fs.log == [
            "copy \(Self.download) -> \(Self.staging)",
            "unquarantine \(Self.staging)",
            "rename \(Self.staging) -> \(Self.dest)",
            "trash \(Self.download)",
        ])
        #expect(Self.onlyStagingUnquarantined(fs))
    }

    @Test func translocatedFromApplicationsSwapsInTheCopyThenTrashesTheOldApp() throws {
        let (fs, p) = try Self.translocatedFromApplications()
        #expect(p.destinationExists && p.destinationIsOriginal && !p.trashOriginal)
        let old = fs.ids[Self.dest]!
        let out = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(out == .init(installed: Self.url(Self.dest)))
        #expect(fs.log == [
            "copy \(Self.translocated) -> \(Self.staging)",
            "unquarantine \(Self.staging)",
            "swap \(Self.staging) <-> \(Self.dest)",
            "trash \(Self.staging)",
        ])
        // The installed path was never empty, the new copy is there, and
        // the item in the Trash is the old app.
        #expect(fs.wentMissing.isEmpty)
        #expect(fs.ids[Self.dest] == fs.lastCopyID)
        #expect(fs.trashedIDs == [old])
        #expect(Self.onlyStagingUnquarantined(fs))
    }

    @Test func aFailedSwapLeavesTheOriginalInstalled() throws {
        let (fs, p) = try Self.translocatedFromApplications()
        let old = fs.ids[Self.dest]!
        fs.fail = ["swap"]
        #expect(throws: AppMoveError.self) { try Self.mover(fs).install(p, replaceExisting: false) }
        #expect(fs.ids[Self.dest] == old)
        #expect(fs.wentMissing.isEmpty)
        #expect(fs.trashed.isEmpty)
        #expect(!fs.exists(Self.url(Self.staging)))
    }

    @Test func aReplacedAppThatWontGoToTheTrashLeavesTheNewInstallUsable() throws {
        let (fs, p) = try Self.translocatedFromApplications()
        let old = fs.ids[Self.dest]!
        fs.fail = ["trash:\(Self.staging)"]
        let out = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(out.installed.path == Self.dest)
        #expect(out.replacedLeftBehind?.path == Self.staging)
        #expect(fs.ids[Self.dest] == fs.lastCopyID)
        #expect(fs.signatureMatchesRunningApp(Self.url(Self.dest)))
        #expect(fs.ids[Self.staging] == old)   // kept, not deleted
        #expect(!fs.log.contains("rm \(Self.staging)"))
    }

    @Test func anOriginalReplacedWhileThePromptWasOpenIsLeftAlone() throws {
        // Finder replaces /Applications/Owlink.app while "Move to Applications?" is up.
        let (fs, p) = try Self.translocatedFromApplications()
        let other = fs.replace(Self.dest)
        #expect(throws: AppMoveError.destinationChanged(Self.url(Self.dest))) {
            try Self.mover(fs).install(p, replaceExisting: false)
        }
        #expect(fs.ids[Self.dest] == other)
        #expect(fs.trashed.isEmpty)
        #expect(!fs.log.contains { $0.hasPrefix("swap") })
        #expect(!fs.exists(Self.url(Self.staging)))
    }

    @Test func anAppTheUserAgreedToReplaceThatWasThenReplacedIsLeftAlone() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.dest, Self.download], writable: [Self.apps])
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        let other = fs.replace(Self.dest)
        #expect(throws: AppMoveError.destinationChanged(Self.url(Self.dest))) {
            try Self.mover(fs).install(p, replaceExisting: true)
        }
        #expect(fs.ids[Self.dest] == other)
        #expect(fs.trashed.isEmpty)
        #expect(fs.exists(Self.url(Self.download)))
    }

    @Test func aReplacementBetweenTheLookAndTheSwapIsSwappedBack() throws {
        let (fs, p) = try Self.translocatedFromApplications()
        var other: Int?
        fs.beforeSwap = { f in
            if other == nil { other = f.replace(Self.dest) }
        }
        #expect(throws: AppMoveError.destinationChanged(Self.url(Self.dest))) {
            try Self.mover(fs).install(p, replaceExisting: false)
        }
        #expect(fs.ids[Self.dest] == other)
        #expect(fs.trashed.isEmpty)
        #expect(!fs.exists(Self.url(Self.staging)))
    }

    @Test func translocatedFromDownloadsTrashesTheRealOriginalNotTheTranslocatedPath() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download, Self.translocated], writable: [Self.apps])
        let p = try Self.plan(.translocated(original: Self.url(Self.download)), source: Self.translocated, fs: fs)
        _ = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(fs.trashed == [Self.download])
        #expect(fs.log.first == "copy \(Self.translocated) -> \(Self.staging)")
        #expect(Self.onlyStagingUnquarantined(fs))
    }

    @Test func aDifferentItemAtTheOriginalsPathIsNotTrashed() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download, Self.translocated], writable: [Self.apps])
        let p = try Self.plan(.translocated(original: Self.url(Self.download)), source: Self.translocated, fs: fs)
        let other = fs.replace(Self.download)   // a new download took the name
        let out = try Self.mover(fs).install(p, replaceExisting: false)
        #expect(out.installed.path == Self.dest)
        #expect(fs.trashed.isEmpty)
        #expect(fs.ids[Self.download] == other)
    }

    @Test func translocatedWithAnUnknownOriginalTrashesNothing() throws {
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
        fs.watch = [Self.dest]
        let old = fs.ids[Self.dest]!
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(p.destinationExists && !p.destinationIsOriginal)
        #expect(throws: AppMoveError.destinationExists(Self.url(Self.dest))) {
            try Self.mover(fs).install(p, replaceExisting: false)
        }
        #expect(fs.log.isEmpty)   // nothing written, nothing unquarantined
        // With the user's yes it goes to the Trash (not deleted) and is replaced.
        _ = try Self.mover(fs).install(p, replaceExisting: true)
        #expect(fs.trashed == [Self.staging, Self.download])
        #expect(fs.trashedIDs.first == old)
        #expect(fs.wentMissing.isEmpty)
        #expect(!fs.log.contains { $0.hasPrefix("rm ") })
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

    @Test func aCopyThatIsntTheRunningAppStopsBeforeQuarantineIsTouched() throws {
        // The bundle at the source path was swapped for another, validly
        // signed one after launch: its copy must not lose its quarantine.
        let fs = FakeInstallFS(items: [Self.apps, Self.dest, Self.download], writable: [Self.apps])
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        fs.replace(Self.download, signer: "someone else")
        let old = fs.ids[Self.dest]
        #expect(throws: AppMoveError.signatureInvalid) { try Self.mover(fs).install(p, replaceExisting: true) }
        #expect(fs.quarantineRemovedUnder.isEmpty)
        #expect(!fs.exists(Self.url(Self.staging)))
        #expect(fs.ids[Self.dest] == old && fs.trashed.isEmpty)
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

    @Test func aFailedRenameDropsTheCopy() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        fs.fail = ["rename"]
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(throws: AppMoveError.self) { try Self.mover(fs).install(p, replaceExisting: false) }
        #expect(fs.items == [Self.apps, Self.download])
    }

    @Test func aDestinationThatAppearedAfterThePlanIsNotReplacedWithoutAsking() throws {
        let fs = FakeInstallFS(items: [Self.apps, Self.download], writable: [Self.apps])
        let p = try Self.plan(.elsewhere(quarantined: true), source: Self.download, fs: fs)
        #expect(!p.destinationExists)
        fs.items.insert(Self.dest)   // dropped in while the question was up
        #expect(throws: AppMoveError.destinationExists(Self.url(Self.dest))) {
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

/// The staged copy must be the running app, on real signed bundles: tiny
/// ones made here and signed ad hoc with /usr/bin/codesign. The expected
/// identity is taken from bundle A, standing in for the running process
/// (CodeIdentity.runningProcess() reads the same two things from the
/// running code). A copy of A matches; B, a different bundle with a valid
/// signature of its own, does not, nor does a tampered copy of A.
@Suite struct CodeSignatureOnDiskTests {
    /// - executable: what Contents/MacOS/Tiny is a copy of.
    /// - designatedByIdentifier: sign with an explicit designated requirement
    ///   on the identifier, as a Developer ID signature carries (with its
    ///   anchor and team), instead of the implicit cdhash one ad hoc gets.
    static func makeSignedApp(at app: URL, identifier: String = "invalid.owlink.test.tiny", extra: String? = nil,
                              executable: String = "/usr/bin/true", designatedByIdentifier: Bool = false) throws {
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: executable), to: macos.appendingPathComponent("Tiny"))
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleExecutable": "Tiny",
                                   "CFBundlePackageType": "APPL", "CFBundleName": "Tiny"]
        if let extra { info["OwlinkTestExtra"] = extra }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Contents/Info.plist"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-"]
            + (designatedByIdentifier ? ["-r=designated => identifier \"\(identifier)\""] : [])
            + [app.path]
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        try #require(p.terminationStatus == 0)
    }

    /// The check the mover used before: any intact signature.
    static func anyValidSignature(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }

    static func tmp(_ tag: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("owlink-\(tag)-\(UUID().uuidString)")
    }

    @Test func onlyACopyOfTheRunningAppMatches() throws {
        let tmp = Self.tmp("sig")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("a/Tiny.app")
        let b = tmp.appendingPathComponent("b/Tiny.app")
        try Self.makeSignedApp(at: a)
        try Self.makeSignedApp(at: b, identifier: "invalid.owlink.test.other")
        let me = try #require(CodeIdentity.of(bundleAt: a))
        let copy = tmp.appendingPathComponent("Applications/Tiny.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LiveAppInstallFileSystem(expectedCode: me).copy(a, to: copy)
        #expect(LiveAppInstallFileSystem(expectedCode: me).signatureMatchesRunningApp(copy))
        // B is validly signed (the old check passed it) but isn't this app.
        #expect(Self.anyValidSignature(b))
        #expect(!me.matches(bundleAt: b))
        #expect(!LiveAppInstallFileSystem(expectedCode: me).signatureMatchesRunningApp(b))
        // No identity to compare with: nothing matches.
        #expect(!LiveAppInstallFileSystem(expectedCode: nil).signatureMatchesRunningApp(copy))
        // A tampered copy, and a bundle with no signature, fail.
        let plist = copy.appendingPathComponent("Contents/Info.plist")
        var d = try Data(contentsOf: plist); d.append(contentsOf: Array("\n".utf8))
        try FileManager.default.removeItem(at: plist)
        try d.write(to: plist)
        #expect(!me.matches(bundleAt: copy))
        #expect(me.matches(bundleAt: a))
        let junk = tmp.appendingPathComponent("Junk.app/Contents")
        try FileManager.default.createDirectory(at: junk, withIntermediateDirectories: true)
        #expect(!me.matches(bundleAt: junk.deletingLastPathComponent()))
    }

    @Test func theCodeHashPinsTheBuildEvenWhenTheRequirementPasses() throws {
        // Same identifier, so a requirement on the identifier alone (as a
        // looser designated requirement would be) passes both; the code
        // hash tells them apart.
        let tmp = Self.tmp("cdh")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("a/Tiny.app")
        let b = tmp.appendingPathComponent("b/Tiny.app")
        try Self.makeSignedApp(at: a)
        try Self.makeSignedApp(at: b, extra: "another build")
        var req: SecRequirement?
        try #require(SecRequirementCreateWithString("identifier \"invalid.owlink.test.tiny\"" as CFString, [], &req) == errSecSuccess)
        let hashA = try #require(CodeIdentity.of(bundleAt: a)?.cdhash)
        let loose = CodeIdentity(requirement: req!, cdhash: hashA)
        #expect(loose.matches(bundleAt: a))
        #expect(!loose.matches(bundleAt: b))
        #expect(CodeIdentity(requirement: req!, cdhash: nil).matches(bundleAt: b))
    }

    @Test func everySliceOfAUniversalBinaryHasItsHash() throws {
        let tmp = Self.tmp("arch")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let a = tmp.appendingPathComponent("Tiny.app")
        try Self.makeSignedApp(at: a)   // /usr/bin/true: universal
        let slices = CodeSignature.architectures(ofBundleAt: a)
        #expect(slices.count >= 2, "\(slices)")
        #expect(CodeSignature.cdhashes(ofBundleAt: a).count >= 2)
    }

    /// CodeIdentity.runningProcess()'s steps, on a running process given by
    /// its pid instead of SecCodeCopySelf: the designated requirement of the
    /// running code's static code, and the running code's own hash.
    static func identity(ofRunning pid: pid_t) -> CodeIdentity? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid as String: NSNumber(value: pid)] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return nil }
        var st: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &st) == errSecSuccess, let st else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(st, [], &req) == errSecSuccess, let req else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return CodeIdentity(requirement: req, cdhash: hash)
    }

    @Test func theTestRunnerHasARunningIdentity() {
        // Whatever runs the tests (swift test's helper, xctest) is signed,
        // at least ad hoc by the linker, so its identity can be read.
        #expect(CodeIdentity.runningProcess()?.cdhash?.count == 20)
    }

    @Test func aRunningAppMatchesItsOwnCodeOnDisk() throws {
        // Not the test runner: it is the toolchain's binary, and an ad hoc
        // universal one (CI's swiftpm-testing-helper) has an implicit
        // designated requirement naming only the running slice's hash, so
        // it fails the all-architectures check against its own file. A
        // tiny app here instead, arm64 and x86_64 as a release is, signed
        // with an explicit requirement as a Developer ID app is, started
        // and read by its pid. (Built here: the system's own binaries are
        // arm64e, which an older macOS may not run once re-signed ad hoc.)
        let tmp = Self.tmp("run")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let exe = tmp.appendingPathComponent("waiter")
        let src = tmp.appendingPathComponent("waiter.c")
        try Data("#include <unistd.h>\nint main(void) { pause(); return 0; }\n".utf8).write(to: src)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        cc.arguments = ["clang", "-arch", "arm64", "-arch", "x86_64", src.path, "-o", exe.path]
        try cc.run()
        cc.waitUntilExit()
        try #require(cc.terminationStatus == 0)
        let a = tmp.appendingPathComponent("a/Tiny.app")
        let other = tmp.appendingPathComponent("other/Tiny.app")
        let rebuilt = tmp.appendingPathComponent("rebuilt/Tiny.app")
        try Self.makeSignedApp(at: a, executable: exe.path, designatedByIdentifier: true)
        try Self.makeSignedApp(at: other, identifier: "invalid.owlink.test.other", executable: exe.path,
                               designatedByIdentifier: true)
        try Self.makeSignedApp(at: rebuilt, extra: "another build", executable: exe.path, designatedByIdentifier: true)
        #expect(CodeSignature.architectures(ofBundleAt: a).count == 2)

        let p = Process()
        p.executableURL = a.appendingPathComponent("Contents/MacOS/Tiny")
        try p.run()
        defer { p.terminate(); p.waitUntilExit() }
        let me = try #require(Self.identity(ofRunning: p.processIdentifier))
        #expect(me.cdhash?.count == 20)
        #expect(me.matches(bundleAt: a))
        // A different app, and the same app built differently (its
        // requirement passes, its hash doesn't), don't.
        #expect(!me.matches(bundleAt: other))
        #expect(!me.matches(bundleAt: rebuilt))
        // And the mover's check, on a copy of it.
        let copy = tmp.appendingPathComponent("Applications/Tiny.app")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try LiveAppInstallFileSystem(expectedCode: me).copy(a, to: copy)
        #expect(LiveAppInstallFileSystem(expectedCode: me).signatureMatchesRunningApp(copy))
    }
}

/// The real renames and identities, and the mover end to end on real
/// signed bundles in a temp folder (the Trash is a folder there too).
@Suite struct AppMoverOnDiskTests {
    /// LiveAppInstallFileSystem with the Trash replaced by a temp folder.
    struct TempTrashFS: AppInstallFileSystem {
        var live: LiveAppInstallFileSystem
        var trashFolder: URL
        func exists(_ url: URL) -> Bool { live.exists(url) }
        func identity(_ url: URL) -> FileIdentity? { live.identity(url) }
        func isWritableFolder(_ url: URL) -> Bool { live.isWritableFolder(url) }
        func createFolder(_ url: URL) throws { try live.createFolder(url) }
        func copy(_ from: URL, to: URL) throws { try live.copy(from, to: to) }
        func renameExclusive(_ from: URL, to: URL) throws { try live.renameExclusive(from, to: to) }
        func swap(_ a: URL, _ b: URL) throws { try live.swap(a, b) }
        func remove(_ url: URL) throws { try live.remove(url) }
        func trash(_ url: URL) throws -> URL? {
            let t = trashFolder.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: t)
            return t
        }
        func removeQuarantine(under url: URL) throws { try live.removeQuarantine(under: url) }
        func signatureMatchesRunningApp(_ url: URL) -> Bool { live.signatureMatchesRunningApp(url) }
        func isReadOnlyVolume(_ url: URL) -> Bool { live.isReadOnlyVolume(url) }
    }

    struct Setup {
        var tmp, apps, trash, source, dest: URL
        var fs: TempTrashFS
        var folders: [URL]
    }

    /// tmp/Downloads/Tiny.app (the "running app"), tmp/Applications with an
    /// older Tiny.app already in it.
    static func setup() throws -> Setup {
        let tmp = CodeSignatureOnDiskTests.tmp("mv")
        let apps = tmp.appendingPathComponent("Applications", isDirectory: true)
        let trash = tmp.appendingPathComponent("Trash", isDirectory: true)
        let source = tmp.appendingPathComponent("Downloads/Tiny.app")
        let dest = apps.appendingPathComponent("Tiny.app", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try CodeSignatureOnDiskTests.makeSignedApp(at: source)
        try CodeSignatureOnDiskTests.makeSignedApp(at: dest, extra: "old version")
        let me = try #require(CodeIdentity.of(bundleAt: source))
        let fs = TempTrashFS(live: LiveAppInstallFileSystem(expectedCode: me), trashFolder: trash)
        return Setup(tmp: tmp, apps: apps, trash: trash, source: source, dest: dest, fs: fs,
                     folders: [apps, tmp.appendingPathComponent("home/Applications")])
    }

    static func marker(_ app: URL) -> String? {
        (NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any])?["OwlinkTestExtra"] as? String
    }

    @Test func renamesNeverOverwriteAndSwapsExchange() throws {
        let tmp = CodeSignatureOnDiskTests.tmp("ren")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let a = tmp.appendingPathComponent("a"), b = tmp.appendingPathComponent("b")
        try Data("A".utf8).write(to: a); try Data("B".utf8).write(to: b)
        let ia = FileIdentity.of(a), ib = FileIdentity.of(b)
        #expect(ia != nil && ia != ib)
        let fs = LiveAppInstallFileSystem(expectedCode: nil)
        #expect(throws: (any Error).self) { try fs.renameExclusive(a, to: b) }
        #expect(try String(contentsOf: b, encoding: .utf8) == "B")
        try fs.swap(a, b)
        #expect(try String(contentsOf: a, encoding: .utf8) == "B")
        #expect(FileIdentity.of(a) == ib && FileIdentity.of(b) == ia)
        // A new file at a path is a different identity.
        try FileManager.default.removeItem(at: a)
        try Data("B".utf8).write(to: a)
        #expect(FileIdentity.of(a) != ib)
        #expect(FileIdentity.of(tmp.appendingPathComponent("none")) == nil)
    }

    @Test func replacingAnOlderCopySwapsAndTrashesTheOldOne() throws {
        let s = try Self.setup()
        defer { try? FileManager.default.removeItem(at: s.tmp) }
        let p = try AppMovePlan.make(location: .elsewhere(quarantined: false), source: s.source, folders: s.folders, fs: s.fs)
        #expect(p.destinationExists)
        let out = try AppMover(fs: s.fs).install(p, replaceExisting: true)
        #expect(out == .init(installed: s.dest))
        #expect(Self.marker(s.dest) == nil)   // the new one
        #expect(s.fs.signatureMatchesRunningApp(s.dest))
        let trashed = try FileManager.default.contentsOfDirectory(at: s.trash, includingPropertiesForKeys: nil)
        #expect(trashed.count == 2)   // the old app and the original
        #expect(trashed.contains { Self.marker($0) == "old version" })
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.apps.path) == ["Tiny.app"])
    }

    @Test func anAppReplacedAtTheDestinationWhileThePromptIsOpenIsKept() throws {
        let s = try Self.setup()
        defer { try? FileManager.default.removeItem(at: s.tmp) }
        let p = try AppMovePlan.make(location: .elsewhere(quarantined: false), source: s.source, folders: s.folders, fs: s.fs)
        // Finder replaces it with another copy while the question is up.
        try FileManager.default.removeItem(at: s.dest)
        try CodeSignatureOnDiskTests.makeSignedApp(at: s.dest, extra: "dragged in")
        #expect(throws: AppMoveError.destinationChanged(s.dest)) {
            try AppMover(fs: s.fs).install(p, replaceExisting: true)
        }
        #expect(Self.marker(s.dest) == "dragged in")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.trash.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.apps.path) == ["Tiny.app"])
        #expect(FileManager.default.fileExists(atPath: s.source.path))
    }

    @Test func aDifferentSignedAppAtTheSourcePathIsNotInstalled() throws {
        let s = try Self.setup()
        defer { try? FileManager.default.removeItem(at: s.tmp) }
        let p = try AppMovePlan.make(location: .elsewhere(quarantined: false), source: s.source, folders: s.folders, fs: s.fs)
        try FileManager.default.removeItem(at: s.source)
        try CodeSignatureOnDiskTests.makeSignedApp(at: s.source, identifier: "invalid.owlink.test.other")
        QuarantineOnDiskTests.setQ(s.source)
        #expect(throws: AppMoveError.signatureInvalid) { try AppMover(fs: s.fs).install(p, replaceExisting: true) }
        #expect(Self.marker(s.dest) == "old version")
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.apps.path) == ["Tiny.app"])
        #expect(Quarantine.has(s.source))
    }
}
