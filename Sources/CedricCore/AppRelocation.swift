import Darwin
import Foundation
import Security

/// Where the running Owlink.app is, and the "Move to Applications" install
/// (docs/updates.md, "Installing"). After LetsMove's idea, our own code.
///
/// Why: Sparkle can't update an app macOS runs through App Translocation
/// (a read-only random path under …/AppTranslocation/, which a quarantined
/// download gets until the user moves it with Finder; a scripted Finder
/// `move` or `/bin/mv` into /Applications was seen to keep it, 0.6.0 QA), or
/// from a read-only disk image. Sparkle then says Owlink "can't be updated
/// if it's running from the location it was downloaded to".
///
/// This is not a Gatekeeper bypass. It runs only in an app that is already
/// running, so Gatekeeper has already passed it (and the user said Open on
/// a first launch). The only quarantine it removes is on the copy it has
/// just written into the Applications folder the user chose, and only once
/// that copy is checked to be the running app (its designated requirement
/// and code hash); never on the download, the disk image, the translocated
/// original or anything else.
public enum AppLocation: Equatable, Sendable {
    /// In /Applications or ~/Applications (or a folder inside one): fine.
    case applications
    /// Run through App Translocation; `original` is where the bundle
    /// really is (it may already be /Applications/Owlink.app), when macOS
    /// says.
    case translocated(original: URL?)
    /// On a read-only volume under /Volumes (a mounted disk image).
    case diskImage
    /// Anywhere else (Downloads, Desktop, a build folder…). `quarantined`:
    /// the bundle carries com.apple.quarantine (it was downloaded).
    case elsewhere(quarantined: Bool)

    /// Whether this location gets Move to Applications: anywhere but an
    /// Applications folder (translocated, a disk image, Downloads, a copy
    /// unpacked anywhere else, quarantined or not). Development launches
    /// are kept out by `shouldOffer`, not here.
    public var offersMove: Bool {
        switch self {
        case .applications: return false
        case .translocated, .diskImage, .elsewhere: return true
        }
    }

    /// The whole launch-time decision: a release build (`checksEnabled`
    /// false: no check build, no debug build), running as a .app bundle
    /// (not `swift run`), that the user hasn't told to stop asking, outside
    /// Applications.
    public static func shouldOffer(_ location: AppLocation, bundle: URL,
                                   checksEnabled: Bool, suppressed: Bool) -> Bool {
        !checksEnabled && !suppressed && bundle.pathExtension == "app" && location.offersMove
    }

    /// Path component macOS puts in every translocated path.
    static let translocationMarker = "/AppTranslocation/"

    /// Pure classification, for tests and for `current()`.
    /// - bundle: the running bundle's URL (Bundle.main.bundleURL).
    /// - translocated: what SecTranslocateIsTranslocatedURL said (nil when it
    ///   couldn't be asked; then the path marker decides).
    /// - applicationsFolders: /Applications and ~/Applications.
    public static func classify(bundle: URL, translocated: Bool?, original: URL?,
                                applicationsFolders: [URL], onReadOnlyVolume: Bool,
                                quarantined: Bool) -> AppLocation {
        let path = bundle.standardizedFileURL.path
        if translocated ?? path.contains(translocationMarker) {
            return .translocated(original: original)
        }
        if isInside(bundle, anyOf: applicationsFolders) { return .applications }
        if onReadOnlyVolume && path.hasPrefix("/Volumes/") { return .diskImage }
        return .elsewhere(quarantined: quarantined)
    }

    /// `url` is strictly inside one of `folders` (component-wise, after
    /// resolving symlinks, so /Applications2 isn't /Applications).
    public static func isInside(_ url: URL, anyOf folders: [URL]) -> Bool {
        let parts = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return folders.contains { folder in
            let f = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            return parts.count > f.count && Array(parts.prefix(f.count)) == f
        }
    }

    /// /Applications and the user's ~/Applications.
    public static func applicationsFolders(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        [URL(fileURLWithPath: "/Applications", isDirectory: true),
         home.appendingPathComponent("Applications", isDirectory: true)]
    }

    /// The running bundle's location, asking Security.framework about
    /// translocation through dlsym (SecTranslocate* are SPI-ish C functions
    /// in Security.framework, exported since macOS 10.12, without a public
    /// header in every SDK).
    public static func current(bundle: URL = Bundle.main.bundleURL) -> AppLocation {
        let t = Translocation.isTranslocated(bundle)
        let original = (t ?? false) ? Translocation.originalURL(bundle) : nil
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return classify(bundle: bundle, translocated: t, original: original,
                        applicationsFolders: applicationsFolders(), onReadOnlyVolume: readOnly,
                        quarantined: Quarantine.has(bundle))
    }
}

/// SecTranslocateIsTranslocatedURL / SecTranslocateCreateOriginalPathForURL,
/// looked up at run time.
public enum Translocation {
    private typealias IsFn = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
    private typealias OriginalFn = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?

    private static func symbol(_ name: String) -> UnsafeMutableRawPointer? {
        guard let h = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY | RTLD_NOLOAD)
                ?? dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY)
        else { return nil }
        return dlsym(h, name)
    }

    /// true/false from Security.framework, or nil when the function is
    /// missing or fails (then the caller falls back to the path).
    public static func isTranslocated(_ url: URL) -> Bool? {
        guard let p = symbol("SecTranslocateIsTranslocatedURL") else { return nil }
        let fn = unsafeBitCast(p, to: IsFn.self)
        var result = false
        guard fn(url as CFURL, &result, nil) else { return nil }
        return result
    }

    /// The bundle's real location behind a translocated path, or nil.
    public static func originalURL(_ url: URL) -> URL? {
        guard let p = symbol("SecTranslocateCreateOriginalPathForURL") else { return nil }
        let fn = unsafeBitCast(p, to: OriginalFn.self)
        guard let u = fn(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return u as URL
    }
}

/// com.apple.quarantine, read and (on our own copy only) removed.
public enum Quarantine {
    public static let name = "com.apple.quarantine"

    public static func has(_ url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return false }
            return getxattr(p, name, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        }
    }

    /// Removes the attribute from `root` and everything under it, without
    /// following symlinks. A file that never had it is fine; any other
    /// failure throws.
    public static func removeRecursively(under root: URL) throws {
        try removeOne(root)
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [])
        else { return }
        for case let u as URL in e { try removeOne(u) }
    }

    private static func removeOne(_ url: URL) throws {
        let rc: Int32 = url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return -1 }
            return removexattr(p, name, XATTR_NOFOLLOW)
        }
        if rc != 0 && errno != ENOATTR {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path,
                                                          NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }
}

/// Which file a path named when it was looked at: device, inode and birth
/// time from lstat(2) (not following a symlink). A different item put at
/// the same path (Finder replacing an app, a new download taking a name)
/// has a different identity, so the mover can tell "the app the user was
/// asked about" from "whatever is at that path now".
public struct FileIdentity: Hashable, Sendable {
    public var device: UInt64
    public var inode: UInt64
    public var birthSeconds: Int64
    public var birthNanoseconds: Int64

    public init(device: UInt64, inode: UInt64, birthSeconds: Int64 = 0, birthNanoseconds: Int64 = 0) {
        self.device = device
        self.inode = inode
        self.birthSeconds = birthSeconds
        self.birthNanoseconds = birthNanoseconds
    }

    /// nil when nothing is at `url`.
    public static func of(_ url: URL) -> FileIdentity? {
        var st = stat()
        let rc: Int32 = url.withUnsafeFileSystemRepresentation { p in
            guard let p else { return -1 }
            return lstat(p, &st)
        }
        guard rc == 0 else { return nil }
        return FileIdentity(device: UInt64(bitPattern: Int64(st.st_dev)), inode: UInt64(st.st_ino),
                            birthSeconds: Int64(st.st_birthtimespec.tv_sec),
                            birthNanoseconds: Int64(st.st_birthtimespec.tv_nsec))
    }
}

/// The file operations the move needs, so tests can fail any one of them.
public protocol AppInstallFileSystem {
    func exists(_ url: URL) -> Bool
    /// What is at `url` now (nil: nothing).
    func identity(_ url: URL) -> FileIdentity?
    func isWritableFolder(_ url: URL) -> Bool
    func createFolder(_ url: URL) throws
    func copy(_ from: URL, to: URL) throws
    /// Renames `from` to `to`, failing if anything is at `to`
    /// (renamex_np RENAME_EXCL).
    func renameExclusive(_ from: URL, to: URL) throws
    /// Exchanges the two items in one step (renamex_np RENAME_SWAP): at no
    /// moment is either path empty.
    func swap(_ a: URL, _ b: URL) throws
    func remove(_ url: URL) throws
    /// Moves `url` to the Trash; where it went (nil if unknown).
    @discardableResult func trash(_ url: URL) throws -> URL?
    /// Removes com.apple.quarantine under `url`. The mover only ever
    /// passes the staging copy it wrote.
    func removeQuarantine(under url: URL) throws
    /// The bundle at `url` has an intact code signature that is the
    /// running app's own: its designated requirement and code hash.
    func signatureMatchesRunningApp(_ url: URL) -> Bool
    func isReadOnlyVolume(_ url: URL) -> Bool
}

public enum AppMoveError: Error, Equatable, Sendable {
    /// The destination exists and isn't this app's own original; the
    /// caller must ask before replacing it.
    case destinationExists(URL)
    /// The item at the destination isn't the one there when the user was
    /// asked (it was replaced meanwhile); it is left alone.
    case destinationChanged(URL)
    case noWritableApplicationsFolder
    case copyFailed(String)
    case signatureInvalid
    case quarantineRemovalFailed(String)
    case replaceFailed(String)
}

/// What the move will do, decided before anything is written (and before
/// the user is asked: the identities are what was there then).
public struct AppMovePlan: Equatable, Sendable {
    /// The bundle that's running (maybe a translocated path).
    public var source: URL
    /// Where the bundle really is (the translocation original, or `source`).
    public var original: URL?
    /// The Applications folder it goes into, and the bundle there.
    public var folder: URL
    public var destination: URL
    /// Something is already at `destination`…
    public var destinationExists: Bool
    /// …and this is it. Only this item is ever replaced.
    public var destinationIdentity: FileIdentity?
    /// …and it is this very app's original (translocated from there), so
    /// replacing it needs no extra question.
    public var destinationIsOriginal: Bool
    /// The original goes to the Trash afterwards (a move): only when it is
    /// somewhere writable that isn't the destination or a disk image…
    public var trashOriginal: Bool
    /// …and only if it is still this item.
    public var originalIdentity: FileIdentity?

    public static func make(location: AppLocation, source: URL, folders: [URL],
                            fs: AppInstallFileSystem) throws -> AppMovePlan {
        // /Applications when it's writable (an admin user), else ~/Applications.
        guard let folder = folders.first(where: { fs.isWritableFolder($0) })
                ?? folders.dropFirst().first(where: { !fs.exists($0) })
        else { throw AppMoveError.noWritableApplicationsFolder }
        let name = source.lastPathComponent
        let destination = folder.appendingPathComponent(name, isDirectory: true)
        let original: URL?
        switch location {
        case .translocated(let o): original = o
        default: original = source
        }
        let destinationIsOriginal = original.map { same($0, destination) } ?? false
        let trashOriginal: Bool
        switch location {
        case .translocated:
            trashOriginal = original.map { !destinationIsOriginal && fs.exists($0) && !fs.isReadOnlyVolume($0) } ?? false
        case .elsewhere:
            trashOriginal = !same(source, destination) && !fs.isReadOnlyVolume(source)
        case .diskImage, .applications:
            trashOriginal = false
        }
        let destinationIdentity = fs.identity(destination)
        return AppMovePlan(source: source, original: original, folder: folder, destination: destination,
                           destinationExists: destinationIdentity != nil || fs.exists(destination),
                           destinationIdentity: destinationIdentity,
                           destinationIsOriginal: destinationIsOriginal,
                           trashOriginal: trashOriginal,
                           originalIdentity: trashOriginal ? original.flatMap { fs.identity($0) } : nil)
    }

    public static func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Copies the running bundle into Applications as LetsMove does, but in
/// steps that each undo themselves on failure:
///  1. copy `source` to a hidden staging bundle beside the destination
///     (same volume, so step 4 is a rename);
///  2. check the copy is the running app: intact signature, the running
///     app's designated requirement and code hash;
///  3. remove com.apple.quarantine from the staging copy only;
///  4. publish: an existing destination (only the very item the plan saw)
///     is exchanged with the staging copy in one atomic rename, so the
///     installed path always holds a whole app; the displaced old app,
///     now at the staging name, goes to the Trash (never deleted). With no
///     destination, an exclusive rename that never overwrites;
///  5. the original goes to the Trash when `plan.trashOriginal`, if it is
///     still the item the plan saw. A failure here (or in 4's Trash step)
///     is reported but the install stands.
/// Any failure in 1–4 removes the staging copy and leaves the destination
/// as it was.
public struct AppMover {
    public var fs: AppInstallFileSystem
    public var makeStagingName: () -> String

    public init(fs: AppInstallFileSystem,
                makeStagingName: @escaping () -> String = { ".Owlink-moving-\(UUID().uuidString).app" }) {
        self.fs = fs
        self.makeStagingName = makeStagingName
    }

    public struct Outcome: Equatable, Sendable {
        public var installed: URL
        /// The original couldn't go to the Trash (a note for the user).
        public var originalLeftBehind: URL? = nil
        /// The replaced app couldn't go to the Trash and is still here,
        /// under the hidden staging name, beside the new install.
        public var replacedLeftBehind: URL? = nil
    }

    /// `replaceExisting`: the user agreed to replace a destination that
    /// isn't this app's original.
    public func install(_ plan: AppMovePlan, replaceExisting: Bool) throws -> Outcome {
        if plan.destinationExists && !plan.destinationIsOriginal && !replaceExisting {
            throw AppMoveError.destinationExists(plan.destination)
        }
        if !fs.exists(plan.folder) {
            do { try fs.createFolder(plan.folder) } catch { throw AppMoveError.noWritableApplicationsFolder }
        }
        let staging = plan.folder.appendingPathComponent(makeStagingName(), isDirectory: true)
        func dropStaging() { try? fs.remove(staging) }

        do { try fs.copy(plan.source, to: staging) } catch {
            dropStaging()
            throw AppMoveError.copyFailed(String(describing: error))
        }
        guard fs.signatureMatchesRunningApp(staging) else { dropStaging(); throw AppMoveError.signatureInvalid }
        do { try fs.removeQuarantine(under: staging) } catch {
            dropStaging()
            throw AppMoveError.quarantineRemovalFailed(String(describing: error))
        }

        var replacedLeft: URL?
        if let seen = fs.identity(plan.destination) {
            // Something there the plan didn't expect (it appeared while the
            // question was up): never replaced without the user's yes.
            guard plan.destinationExists, plan.destinationIsOriginal || replaceExisting else {
                dropStaging()
                throw AppMoveError.destinationExists(plan.destination)
            }
            // Not the item the user was asked about (Finder replaced it).
            guard seen == plan.destinationIdentity else {
                dropStaging()
                throw AppMoveError.destinationChanged(plan.destination)
            }
            do { try fs.swap(staging, plan.destination) } catch {
                dropStaging()
                throw AppMoveError.replaceFailed(String(describing: error))
            }
            // `staging` now holds what was at the destination at the swap.
            guard fs.identity(staging) == seen else {
                // Replaced between the look and the swap: swap it back.
                do { try fs.swap(staging, plan.destination) } catch {
                    // Both are kept: the new copy installed, the other item
                    // at the staging name. Nothing is removed.
                    throw AppMoveError.replaceFailed(String(describing: error))
                }
                dropStaging()
                throw AppMoveError.destinationChanged(plan.destination)
            }
            // Just checked: it is the replaced app, so it goes to the Trash.
            do { try fs.trash(staging) } catch { replacedLeft = staging }
        } else {
            do { try fs.renameExclusive(staging, to: plan.destination) } catch {
                dropStaging()
                if fs.identity(plan.destination) != nil, !plan.destinationExists {
                    throw AppMoveError.destinationExists(plan.destination)
                }
                throw AppMoveError.replaceFailed(String(describing: error))
            }
        }

        var left: URL?
        if plan.trashOriginal, let o = plan.original, !AppMovePlan.same(o, plan.destination) {
            // Only the item that was there; something new at that path stays.
            if let id = plan.originalIdentity, fs.identity(o) == id {
                do { try fs.trash(o) } catch { left = o }
            }
        }
        return Outcome(installed: plan.destination, originalLeftBehind: left, replacedLeftBehind: replacedLeft)
    }

    /// The shell command that reopens `app` once process `pid` has quit
    /// (up to a minute), run detached by the app just before it quits.
    /// Arguments, not interpolation: `sh -c script sh PID PATH`.
    public static func relaunchCommand(pid: Int32, app: URL) -> [String] {
        let script = "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ $i -lt 600 ]; do /bin/sleep 0.1; i=$((i+1)); done; "
            + "/bin/kill -0 \"$1\" 2>/dev/null || /usr/bin/open \"$2\""
        return ["/bin/sh", "-c", script, "sh", String(pid), app.path]
    }
}

/// The real file system. `expectedCode`: the signing identity a staged
/// copy must have (the running process's, by default).
public struct LiveAppInstallFileSystem: AppInstallFileSystem {
    public var expectedCode: CodeIdentity?
    public init(expectedCode: CodeIdentity? = CodeIdentity.runningProcess()) {
        self.expectedCode = expectedCode
    }
    private var fm: FileManager { .default }
    public func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    public func identity(_ url: URL) -> FileIdentity? { FileIdentity.of(url) }
    public func isWritableFolder(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue && fm.isWritableFile(atPath: url.path)
    }
    public func createFolder(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
    public func copy(_ from: URL, to: URL) throws { try fm.copyItem(at: from, to: to) }
    public func renameExclusive(_ from: URL, to: URL) throws { try Self.renamex(from, to, UInt32(RENAME_EXCL)) }
    public func swap(_ a: URL, _ b: URL) throws { try Self.renamex(a, b, UInt32(RENAME_SWAP)) }
    public func remove(_ url: URL) throws { try fm.removeItem(at: url) }
    @discardableResult public func trash(_ url: URL) throws -> URL? {
        var out: NSURL?
        try fm.trashItem(at: url, resultingItemURL: &out)
        return out as URL?
    }
    public func removeQuarantine(under url: URL) throws { try Quarantine.removeRecursively(under: url) }
    public func signatureMatchesRunningApp(_ url: URL) -> Bool { expectedCode?.matches(bundleAt: url) ?? false }
    public func isReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }

    static func renamex(_ from: URL, _ to: URL, _ flags: UInt32) throws {
        let rc: Int32 = from.withUnsafeFileSystemRepresentation { f in
            to.withUnsafeFileSystemRepresentation { t in
                guard let f, let t else { errno = EINVAL; return -1 }
                return renamex_np(f, t, flags)
            }
        }
        if rc != 0 {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: to.path,
                                                          NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }
}

/// The signing identity a staged copy must match: a designated
/// requirement (for a Developer ID release: its bundle identifier, Apple's
/// Developer ID anchor and the team) and the code directory hash of the
/// main executable (this exact build). The staged bundle passes when its
/// signature is intact (all architectures, nested code, strict), it
/// satisfies the requirement, and one of its architectures' code hash is
/// `cdhash`.
public struct CodeIdentity: @unchecked Sendable {
    public var requirement: SecRequirement
    public var cdhash: Data?

    public init(requirement: SecRequirement, cdhash: Data?) {
        self.requirement = requirement
        self.cdhash = cdhash
    }

    /// The running process's identity, or nil when it can't be read (then
    /// no copy matches and the move fails safe).
    public static func runningProcess() -> CodeIdentity? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var st: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &st) == errSecSuccess, let st else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(st, [], &req) == errSecSuccess, let req else { return nil }
        // The running code's own hash, as the kernel validated it.
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(unsafeBitCast(me, to: SecStaticCode.self), [], &info) == errSecSuccess,
              let hash = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        return CodeIdentity(requirement: req, cdhash: hash)
    }

    /// A bundle's identity on disk (its default architecture's hash).
    public static func of(bundleAt url: URL) -> CodeIdentity? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var req: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(code, [], &req) == errSecSuccess, let req else { return nil }
        return CodeIdentity(requirement: req, cdhash: CodeSignature.cdhash(code))
    }

    public func matches(bundleAt url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { return false }
        guard let cdhash else { return true }
        return CodeSignature.cdhashes(ofBundleAt: url).contains(cdhash)
    }
}

/// Code directory hashes of a bundle on disk.
public enum CodeSignature {
    static func cdhash(_ code: SecStaticCode) -> Data? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, [], &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data
    }

    /// One hash per architecture of the main executable (a universal app
    /// has one per slice; the running process is one of them).
    public static func cdhashes(ofBundleAt url: URL) -> Set<Data> {
        var out = Set<Data>()
        var code: SecStaticCode?
        if SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code, let h = cdhash(code) {
            out.insert(h)
        }
        for (type, subtype) in architectures(ofBundleAt: url) {
            let attrs: [String: Any] = [kSecCodeAttributeArchitecture as String: NSNumber(value: type),
                                        kSecCodeAttributeSubarchitecture as String: NSNumber(value: subtype)]
            var c: SecStaticCode?
            if SecStaticCodeCreateWithPathAndAttributes(url as CFURL, [], attrs as CFDictionary, &c) == errSecSuccess,
               let c, let h = cdhash(c) {
                out.insert(h)
            }
        }
        return out
    }

    /// (cputype, cpusubtype) of each slice of a universal main executable,
    /// or of `url` when it is an executable file (empty for a thin one or
    /// anything unreadable).
    static func architectures(ofBundleAt url: URL) -> [(Int32, Int32)] {
        // A bundle's main executable, or `url` itself when it is one.
        guard let exe = Bundle(url: url)?.executableURL ?? (url.hasDirectoryPath ? nil : url),
              let h = try? FileHandle(forReadingFrom: exe) else { return [] }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 8 + 20 * 32), head.count >= 8 else { return [] }
        func be32(_ o: Int) -> UInt32 {
            head[o..<(o + 4)].reduce(0) { $0 << 8 | UInt32($1) }
        }
        let magic = be32(0)
        let entry: Int
        switch magic {
        case 0xcafebabe: entry = 20   // fat_arch
        case 0xcafebabf: entry = 32   // fat_arch_64
        default: return []
        }
        let n = Int(be32(4))
        var out: [(Int32, Int32)] = []
        for i in 0..<min(n, 20) {
            let o = 8 + i * entry
            guard o + 8 <= head.count else { break }
            out.append((Int32(bitPattern: be32(o)), Int32(bitPattern: be32(o + 4) & 0x00ff_ffff)))
        }
        return out
    }
}
