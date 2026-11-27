// Measures launch-to-first-window for any app, the same way for each, so
// Owlink can be compared with TextEdit and VS Code:
//
//   swift Scripts/launch-time.swift [--runs 5] APP.app [APP.app ...]
//
// For each run: launch a new instance with NSWorkspace, poll the window
// server (CGWindowList, which works with the screen locked) every 5 ms
// until the app owns a normal-level window at least 200 points tall, record
// the time, quit the app, wait for it to exit, pause. Prints each run and
// the median. "Cold" here means the app isn't running; the file cache is
// warm after the first run (purging it needs root).
//
// Owlink (bundle id net.mindtricks.cedric, or executable Cedric) is
// launched only if it is a check build, decided from the bundle before
// anything runs: Info.plist CedricCheckBuild = true and no embedded
// Sparkle.framework (Scripts/check-env.sh, cedric_require_check_build).
// Every Owlink launch gets a temp CEDRIC_SESSION_DIR and
// CEDRIC_REPLACE_UNDO_DIR of its own, removed at the end, so the real
// session, cli-token and Replace in Files undo copies in ~/Library/
// Application Support/Cedric are never read or written. A release build
// ignores both and is refused with exit 1; time one only in a disposable
// macOS user account or VM. -ApplePersistenceIgnoreState only stops
// AppKit's window restoration, not Owlink's own session.
import AppKit
import CoreGraphics

var runs = 5
var apps: [String] = []
var args = CommandLine.arguments.dropFirst()
while let a = args.popFirst() {
    if a == "--runs", let n = args.popFirst().flatMap(Int.init) { runs = n } else { apps.append(a) }
}

func now() -> Double { Date().timeIntervalSince1970 }

/// Owlink, by its bundle id or executable name.
func isOwlink(_ path: String) -> Bool {
    let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist")
    return info?["CFBundleIdentifier"] as? String == "net.mindtricks.cedric" || info?["CFBundleExecutable"] as? String == "Cedric"
        || FileManager.default.fileExists(atPath: path + "/Contents/MacOS/Cedric")
}

/// Why `path` (an Owlink bundle) is not a check build; nil if it is. Reads
/// the bundle only; runs nothing.
func checkBuildProblem(_ path: String) -> String? {
    guard let info = NSDictionary(contentsOfFile: path + "/Contents/Info.plist") else { return "\(path) has no readable Contents/Info.plist" }
    guard info["CedricCheckBuild"] as? Bool == true else {
        return "\(path) is not marked a check build (Info.plist CedricCheckBuild: \(info["CedricCheckBuild"].map { "\($0)" } ?? "absent")); a release build ignores the test session and undo folders"
    }
    if FileManager.default.fileExists(atPath: path + "/Contents/Frameworks/Sparkle.framework") {
        return "\(path) embeds Sparkle.framework, which only a release build does"
    }
    return nil
}

// Refuse before launching anything.
for path in apps where isOwlink(path) {
    if let why = checkBuildProblem(path) {
        FileHandle.standardError.write(Data("launch-time: refusing to launch: \(why). Build a check build with Scripts/bundle-app.sh (no --release).\n".utf8))
        exit(1)
    }
}

/// A fresh temp folder for one Owlink launch (session and ReplaceUndo).
func isolatedEnvironment() -> (URL, [String: String]) {
    let w = FileManager.default.temporaryDirectory.appendingPathComponent("owlink-launch-time-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: w, withIntermediateDirectories: true)
    var env = ProcessInfo.processInfo.environment
    env["CEDRIC_SESSION_DIR"] = w.appendingPathComponent("session").path
    env["CEDRIC_REPLACE_UNDO_DIR"] = w.appendingPathComponent("replace-undo").path
    return (w, env)
}

func hasWindow(_ pid: pid_t) -> Bool {
    guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return false }
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
        if let b = w[kCGWindowBounds as String] as? [String: Double], (b["Height"] ?? 0) >= 200 { return true }
    }
    return false
}

func launchOnce(_ path: String) -> Double? {
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.createsNewApplicationInstance = true
    cfg.activates = true
    // AppKit apps: don't offer to reopen windows after a killed run.
    // Electron apps (VS Code) treat any argument as a path, so none there.
    if !FileManager.default.fileExists(atPath: path + "/Contents/Frameworks/Electron Framework.framework") {
        cfg.arguments = ["-ApplePersistenceIgnoreState", "YES"]
    }
    var work: URL?
    if isOwlink(path) {
        let (w, env) = isolatedEnvironment()
        work = w
        cfg.environment = env
    }
    defer { if let work { try? FileManager.default.removeItem(at: work) } }
    var app: NSRunningApplication?
    let t0 = now()
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { a, e in
        app = a
        if let e { print("launch error: \(e)") }
        done.signal()
    }
    while done.wait(timeout: .now() + 0.001) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.001)) }
    guard let pid = app?.processIdentifier else { return nil }
    var t1: Double?
    let deadline = t0 + 30
    while now() < deadline {
        if hasWindow(pid) { t1 = now(); break }
        usleep(5000)
    }
    app?.terminate()
    for _ in 0..<100 where !(app?.isTerminated ?? true) { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
    if !(app?.isTerminated ?? true) { app?.forceTerminate(); sleep(1) }
    sleep(2)
    return t1.map { ($0 - t0) * 1000 }
}

for path in apps {
    var samples: [Double] = []
    for i in 1...runs {
        if let ms = launchOnce(path) {
            samples.append(ms)
            print(String(format: "%@ run %d: %.0f ms", (path as NSString).lastPathComponent, i, ms))
        } else {
            print("\((path as NSString).lastPathComponent) run \(i): no window within 30 s")
        }
    }
    samples.sort()
    if !samples.isEmpty {
        print(String(format: "%@ median: %.0f ms (min %.0f, max %.0f, n=%d)", (path as NSString).lastPathComponent,
                     samples[samples.count / 2], samples.first!, samples.last!, samples.count))
    }
}
