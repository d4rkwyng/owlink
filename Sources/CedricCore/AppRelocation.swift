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
/// just written into the Applications folder the user chose; never on the
/// download, the disk image, the translocated original or anything else.
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

    /// Whether to offer Move to Applications: translocated, on a disk
    /// image, or a download sitting outside Applications. A copy someone
    /// built and runs from their own folder (no quarantine) isn't asked.
    public var offersMove: Bool {
        switch self {
        case .applications: return false
        case .translocated, .diskImage: return true
        case .elsewhere(let q): return q
        }
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

/// The file operations the move needs, so tests can fail any one of them.
public protocol AppInstallFileSystem {
    func exists(_ url: URL) -> Bool
    func isWritableFolder(_ url: URL) -> Bool
    func createFolder(_ url: URL) throws
    func copy(_ from: URL, to: URL) throws
    func rename(_ from: URL, to: URL) throws
    func remove(_ url: URL) throws
    func trash(_ url: URL) throws
    /// Removes com.apple.quarantine under `url`. The mover only ever
    /// passes the staging copy it wrote.
    func removeQuarantine(under url: URL) throws
    /// The code signature of the bundle at `url` is intact.
    func signatureIsValid(_ url: URL) -> Bool
    func isReadOnlyVolume(_ url: URL) -> Bool
}

public enum AppMoveError: Error, Equatable, Sendable {
    /// The destination exists and isn't this app's own original; the
    /// caller must ask before replacing it.
    case destinationExists(URL)
    case noWritableApplicationsFolder
    case copyFailed(String)
    case signatureInvalid
    case quarantineRemovalFailed(String)
    case replaceFailed(String)
}

/// What the move will do, decided before anything is written.
public struct AppMovePlan: Equatable, Sendable {
    /// The bundle that's running (maybe a translocated path).
    public var source: URL
    /// Where the bundle really is (the translocation original, or `source`).
    public var original: URL?
    /// The Applications folder it goes into, and the bundle there.
    public var folder: URL
    public var destination: URL
    /// Something is already at `destination`.
    public var destinationExists: Bool
    /// …and it is this very app's original (translocated from there), so
    /// replacing it needs no extra question.
    public var destinationIsOriginal: Bool
    /// The original goes to the Trash afterwards (a move): only when it is
    /// somewhere writable that isn't the destination or a disk image.
    public var trashOriginal: Bool

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
        return AppMovePlan(source: source, original: original, folder: folder, destination: destination,
                           destinationExists: fs.exists(destination), destinationIsOriginal: destinationIsOriginal,
                           trashOriginal: trashOriginal)
    }

    public static func same(_ a: URL, _ b: URL) -> Bool {
        a.resolvingSymlinksInPath().standardizedFileURL.path == b.resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// Copies the running bundle into Applications as LetsMove does, but in
/// steps that each undo themselves on failure:
///  1. copy `source` to a hidden staging bundle beside the destination
///     (same volume, so step 4 is a rename);
///  2. check the copy's code signature;
///  3. remove com.apple.quarantine from the staging copy only;
///  4. an existing destination goes to the Trash (never deleted), then the
///     staging copy is renamed onto the destination;
///  5. the original goes to the Trash when `plan.trashOriginal`. A
///     failure here is reported but the install stands.
/// Any failure in 1–4 removes the staging copy and leaves everything else
/// as it was (step 4 puts a trashed destination back when it can).
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
        public var originalLeftBehind: URL?
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
        guard fs.signatureIsValid(staging) else { dropStaging(); throw AppMoveError.signatureInvalid }
        do { try fs.removeQuarantine(under: staging) } catch {
            dropStaging()
            throw AppMoveError.quarantineRemovalFailed(String(describing: error))
        }
        if fs.exists(plan.destination) {
            do { try fs.trash(plan.destination) } catch {
                dropStaging()
                throw AppMoveError.replaceFailed(String(describing: error))
            }
        }
        do { try fs.rename(staging, to: plan.destination) } catch {
            dropStaging()
            throw AppMoveError.replaceFailed(String(describing: error))
        }
        var left: URL?
        if plan.trashOriginal, let o = plan.original, !AppMovePlan.same(o, plan.destination) {
            do { try fs.trash(o) } catch { left = o }
        }
        return Outcome(installed: plan.destination, originalLeftBehind: left)
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

/// The real file system.
public struct LiveAppInstallFileSystem: AppInstallFileSystem {
    public init() {}
    private var fm: FileManager { .default }
    public func exists(_ url: URL) -> Bool { fm.fileExists(atPath: url.path) }
    public func isWritableFolder(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &dir) && dir.boolValue && fm.isWritableFile(atPath: url.path)
    }
    public func createFolder(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
    public func copy(_ from: URL, to: URL) throws { try fm.copyItem(at: from, to: to) }
    public func rename(_ from: URL, to: URL) throws { try fm.moveItem(at: from, to: to) }
    public func remove(_ url: URL) throws { try fm.removeItem(at: url) }
    public func trash(_ url: URL) throws { try fm.trashItem(at: url, resultingItemURL: nil) }
    public func removeQuarantine(under url: URL) throws { try Quarantine.removeRecursively(under: url) }
    public func signatureIsValid(_ url: URL) -> Bool { CodeSignature.isValid(url) }
    public func isReadOnlyVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
    }
}

/// The code signature of a bundle on disk, checked the way Gatekeeper's
/// static check does (all architectures, nested code, strict).
public enum CodeSignature {
    public static func isValid(_ url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
    }
}
