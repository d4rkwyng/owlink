import Foundation
import Testing

/// Scripts/daily-use.sh, run for real against a stand-in app bundle (a
/// shell script marked as a check build that prints what a daily-use
/// launch prints and records that it ran). Owlink itself is not built or
/// launched.
@Suite(.offPool) struct DailyUseRunnerTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let script = root.appendingPathComponent("Scripts/daily-use.sh")

    struct Fixture {
        let dir: URL, app: URL, out: URL, launches: URL, stubs: URL

        /// What the stand-in recorded: one line per launch.
        var launched: [String] {
            ((try? String(contentsOf: launches, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        }
    }

    func fixture() throws -> Fixture {
        let fm = FileManager.default
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().appendingPathComponent("cedric-dailyuse-runner-\(UUID().uuidString)")
        let app = dir.appendingPathComponent("Standin.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("stubs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("home"), withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
        <key>CFBundleIdentifier</key><string>net.mindtricks.cedric</string>
        <key>CFBundleExecutable</key><string>Cedric</string>
        <key>CFBundlePackageType</key><string>APPL</string>
        <key>CedricCheckBuild</key><true/>
        </dict></plist>

        """.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let exe = macos.appendingPathComponent("Cedric")
        try """
        #!/bin/bash
        me=$(cd "$(dirname "$0")/../.." && pwd -P)
        id=$(plutil -extract CFBundleIdentifier raw -o - "$me/Contents/Info.plist")
        echo "launched app=$me bundle=$id check=${CEDRIC_CHECK:-none}" >> "$STANDIN_LAUNCHES"
        if [ -z "${CEDRIC_CHECK:-}" ]; then echo "metric launch_ms=100.0"; exit 0; fi
        echo "check: note: isolation: bundle=$id app=$me session=$CEDRIC_SESSION_DIR replace-undo=$CEDRIC_REPLACE_UNDO_DIR models=$CEDRIC_MODELS_DIR ai-defaults=$CEDRIC_AI_DEFAULTS"
        echo "check: PASS stand-in $CEDRIC_CHECK"
        echo "check: done 1 passed, 0 failed, 0 known bugs, 0 skipped"

        """.write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        return Fixture(dir: dir, app: app, out: dir.appendingPathComponent("out"), launches: dir.appendingPathComponent("launches.txt"),
                       stubs: dir.appendingPathComponent("stubs"))
    }

    /// A tool of that name that fails, first in the runner's PATH.
    func failing(_ tool: String, in f: Fixture) throws {
        let u = f.stubs.appendingPathComponent(tool)
        try "#!/bin/bash\nexit 1\n".write(to: u, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: u.path)
    }

    /// Runs the runner on the stand-in; status and output.
    func run(_ f: Fixture, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.script.path, "--no-build", "--out", f.out.path] + args + [f.app.path]
        // Its own HOME: the files the runner removes at the end are looked for there.
        p.environment = ["PATH": "\(f.stubs.path):/usr/bin:/bin:/usr/sbin:/sbin", "HOME": f.dir.appendingPathComponent("home").path,
                         "STANDIN_LAUNCHES": f.launches.path, "TMPDIR": NSTemporaryDirectory()]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// No isolated copy, no launch: not of the copy, not of the app itself.
    @Test(arguments: ["codesign", "ditto", "plutil"]) func aCopyThatCannotBePreparedLaunchesNothing(tool: String) throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try failing(tool, in: f)
        let (status, out) = try run(f, ["--flows-only"])
        // (A failing plutil already fails the check-build test before the copy.)
        #expect(status == 1, "\(out)")
        #expect(tool == "plutil" || out.contains("cannot prepare the isolated copy"), "\(out)")
        #expect(out.contains("Nothing was launched") || out.contains("refusing to launch"), "\(out)")
        #expect(f.launched.isEmpty, "launched: \(f.launched)")
        #expect(!FileManager.default.fileExists(atPath: f.out.appendingPathComponent("flows.log").path))
        #expect(!FileManager.default.fileExists(atPath: f.out.appendingPathComponent("summary.md").path))
    }

    /// The normal path: every launch is the copy with its own bundle id,
    /// in the runner's scratch folder, and the runner says so.
    @Test func theNormalPathLaunchesOnlyTheCopy() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (status, out) = try run(f, ["--flows-only"])
        #expect(status == 0, "\(out)")
        let launched = f.launched
        #expect(launched.count == 2, "the self-test and the flows: \(launched)")
        for l in launched {
            #expect(l.contains("bundle=net.mindtricks.cedric.dailyuse "), "\(l)")
            #expect(l.contains("/Owlink-dailyuse.app ") && !l.contains("app=\(f.app.path) "), "\(l)")
        }
        let isolation = try String(contentsOf: f.out.appendingPathComponent("isolation.log"), encoding: .utf8)
        #expect(isolation.hasPrefix("check: PASS isolation: 2 launches ran as the copy (net.mindtricks.cedric.dailyuse)"), "\(isolation)")
        // The scratch folders and suite each launch reported.
        let flows = try String(contentsOf: f.out.appendingPathComponent("flows.log"), encoding: .utf8)
        let note = try #require(flows.split(separator: "\n").first { $0.hasPrefix("check: note: isolation: ") })
        #expect(note.contains(" ai-defaults=net.mindtricks.cedric.dailyuse.ai"))
        for key in ["session=", "replace-undo=", "models="] {
            let value = try #require(note.split(separator: " ").first { $0.hasPrefix(key) }).dropFirst(key.count)
            #expect(value.hasPrefix("/") && !value.contains("/Library/"), "\(key)\(value)")
        }
        // The copy is gone at the end, and the app itself was left alone.
        let id = try String(contentsOf: f.app.appendingPathComponent("Contents/Info.plist"), encoding: .utf8)
        #expect(id.contains("<string>net.mindtricks.cedric</string>"))
    }

    /// A launch that does not report the copy and the scratch folders fails the run.
    @Test func aLaunchThatDoesNotReportTheCopyFailsIsolation() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let exe = f.app.appendingPathComponent("Contents/MacOS/Cedric")
        let text = try String(contentsOf: exe, encoding: .utf8).replacingOccurrences(of: "models=$CEDRIC_MODELS_DIR", with: "models=/elsewhere")
        try text.write(to: exe, atomically: true, encoding: .utf8)
        let (status, out) = try run(f, ["--flows-only"])
        #expect(status == 1, "\(out)")
        #expect(out.contains("check: FAIL isolation: these launches did not report the copy"), "\(out)")
    }

    /// The runner does not look inside the protected support folder.
    @Test func theRunnerDoesNotInspectTheSupportFolder() throws {
        let code = try String(contentsOf: Self.script, encoding: .utf8).split(separator: "\n").filter { !$0.drop(while: { $0 == " " }).hasPrefix("#") }
        #expect(!code.contains { $0.contains("Application Support/Cedric") }, "a command names ~/Library/Application Support/Cedric")
    }

    /// Logs an earlier run left in the same folder are not this run's.
    @Test func anEarlierRunsLogsAreNotInTheSummaryOrTheExitStatus() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try FileManager.default.createDirectory(at: f.out, withIntermediateDirectories: true)
        for old in ["perf-5.log", "budget.log"] {
            try "check: FAIL old speed failure from an earlier run\ncheck: SKIP old skip\n".write(to: f.out.appendingPathComponent(old), atomically: true, encoding: .utf8)
        }
        let (status, out) = try run(f, ["--flows-only"])
        #expect(status == 0, "\(out)")
        let summary = try String(contentsOf: f.out.appendingPathComponent("summary.md"), encoding: .utf8)
        #expect(!summary.contains("old speed failure") && !summary.contains("old skip"), "\(summary)")
        #expect(summary.contains("(not measured: --flows-only)"))
        #expect(summary.contains("- Logs of this invocation: selftest.log flows.log isolation.log"), "\(summary)")
        // This run's own failure still counts.
        let exe = f.app.appendingPathComponent("Contents/MacOS/Cedric")
        let text = try String(contentsOf: exe, encoding: .utf8).replacingOccurrences(of: "check: PASS stand-in", with: "check: FAIL stand-in")
        try text.write(to: exe, atomically: true, encoding: .utf8)
        let (again, _) = try run(f, ["--flows-only"])
        #expect(again == 1)
    }

    @Test func writeBudgetsWithFlowsOnlyIsRejected() throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let (status, out) = try run(f, ["--write-budgets", "--flows-only"])
        #expect(status == 2, "\(out)")
        #expect(out.contains("do not go together"))
        #expect(f.launched.isEmpty)
        let (metrics, _) = try run(f, ["--metrics", "preview_toggle_ms"])
        #expect(metrics == 2, "--metrics without --write-budgets")
        let (unknown, _) = try run(f, ["--write-budgets", "--metrics", "nope_ms"])
        #expect(unknown == 2 && f.launched.isEmpty)
    }
}
