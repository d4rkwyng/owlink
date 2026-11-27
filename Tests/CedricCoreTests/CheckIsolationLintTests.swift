import Foundation
import Testing

/// Scripts/check-isolation-lint.sh: every check script that launches
/// Owlink gives it a temp CEDRIC_SESSION_DIR and CEDRIC_REPLACE_UNDO_DIR
/// (Scripts/check-env.sh), so a check launch never prunes the real
/// ReplaceUndo. Static: nothing is built or launched.
@Suite(.offPool) struct CheckIsolationLintTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Runs the lint on `paths` (none: the real Scripts/*.sh); status and output.
    func lint(_ paths: [String] = []) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.root.appendingPathComponent("Scripts/check-isolation-lint.sh").path] + paths
        p.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Writes each script to a fresh folder; their paths.
    func fixtures(_ scripts: [String: String]) throws -> (URL, [String]) {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-isolation-lint-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        var paths: [String] = []
        for (name, text) in scripts.sorted(by: { $0.key < $1.key }) {
            let u = d.appendingPathComponent(name)
            try text.write(to: u, atomically: true, encoding: .utf8)
            paths.append(u.path)
        }
        return (d, paths)
    }

    @Test func everyScriptInTheCheckoutPasses() throws {
        let (status, out) = try lint()
        #expect(status == 0, "\(out)")
        #expect(out.contains("check-isolation-lint: OK"))
    }

    /// The shape every launching script had before check-env.sh: a temp
    /// session folder and nothing for ReplaceUndo.
    @Test func aLaunchWithOnlyASessionFolderFails() throws {
        let (d, paths) = try fixtures(["old-check.sh": """
            #!/bin/bash
            APP="${1:-dist/Owlink.app}"
            BIN="$APP/Contents/MacOS/Cedric"
            [ -x "$BIN" ] || exit 1
            W=$(mktemp -d)
            env CEDRIC_SESSION_DIR="$W/session" CEDRIC_NO_RESTORE=1 \\
                "$BIN" -ApplePersistenceIgnoreState YES
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("old-check.sh:6: launches the app without sourcing Scripts/check-env.sh first"), "\(out)")
        #expect(out.contains("old-check.sh:6: launches the app before cedric_isolate"), "\(out)")
    }

    @Test func aDebugBinaryLaunchNeedsTheHelperToo() throws {
        let (d, paths) = try fixtures(["debug-check.sh": """
            #!/bin/bash
            BIN=$(swift build --show-bin-path)/CedricApp
            WORK=$(mktemp -d)
            CEDRIC_SESSION_DIR="$WORK/s" CEDRIC_OWL_CHECK="$WORK/o" "$BIN" || status=1
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("debug-check.sh:4: launches the app before cedric_isolate"), "\(out)")
    }

    @Test func isolatingAfterTheFirstLaunchFails() throws {
        let (d, paths) = try fixtures(["late.sh": """
            #!/bin/bash
            BIN="dist/Owlink.app/Contents/MacOS/Cedric"
            W=$(mktemp -d)
            export CEDRIC_SESSION_DIR="$W/s"
            "$BIN" -ApplePersistenceIgnoreState YES
            . Scripts/check-env.sh
            cedric_isolate "$W"
            "$BIN" -ApplePersistenceIgnoreState YES
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("late.sh:5: launches the app before cedric_isolate"), "\(out)")
    }

    @Test func noSessionFolderFails() throws {
        let (d, paths) = try fixtures(["nosession.sh": """
            #!/bin/bash
            BIN="dist/Owlink.app/Contents/MacOS/Cedric"
            W=$(mktemp -d)
            . Scripts/check-env.sh
            cedric_isolate "$W"
            "$BIN" -ApplePersistenceIgnoreState YES
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("nosession.sh:6: launches the app without CEDRIC_SESSION_DIR"), "\(out)")
    }

    /// env -u / a cleaned environment drops the exported folder again.
    @Test func aLaunchThatStripsTheEnvironmentMustSetBothItself() throws {
        let (d, paths) = try fixtures(["strip.sh": """
            #!/bin/bash
            BIN="dist/Owlink.app/Contents/MacOS/Cedric"
            W=$(mktemp -d)
            . Scripts/check-env.sh
            cedric_isolate "$W"
            env -u CEDRIC_REPLACE_UNDO_DIR CEDRIC_SESSION_DIR="$W/s" "$BIN" -ApplePersistenceIgnoreState YES
            env -i CEDRIC_SESSION_DIR="$W/s" CEDRIC_REPLACE_UNDO_DIR="$W/u" "$BIN" -ApplePersistenceIgnoreState YES
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("strip.sh:6: a launch that strips the environment"), "\(out)")
        #expect(!out.contains("strip.sh:7:"), "\(out)")
    }

    @Test func anIsolatedScriptPassesAndInspectionsAreNotLaunches() throws {
        let (d, paths) = try fixtures(["good.sh": """
            #!/bin/bash
            APP="dist/Owlink.app"
            BIN="$APP/Contents/MacOS/Cedric"
            [ -x "$BIN" ] || exit 1
            otool -L "$BIN" | grep -q Sparkle && exit 1
            . Scripts/check-env.sh
            cedric_require_check_build "$APP"
            W=$(mktemp -d)
            cedric_isolate "$W"
            env CEDRIC_SESSION_DIR="$W/s" perl -e 'alarm 60; exec @ARGV' "$BIN" -ApplePersistenceIgnoreState YES
            """, "inspect-only.sh": """
            #!/bin/bash
            BIN="dist/Owlink.app/Contents/MacOS/Cedric"
            lipo -archs "$BIN"
            echo "built $BIN"
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 0, "\(out)")
    }

    @Test func aBundleLaunchWithoutTheCheckBuildGuardFails() throws {
        let (d, paths) = try fixtures(["unguarded.sh": """
            #!/bin/bash
            APP="${1:-dist/Owlink.app}"
            BIN="$APP/Contents/MacOS/Cedric"
            W=$(mktemp -d)
            . Scripts/check-env.sh
            cedric_isolate "$W"
            env CEDRIC_SESSION_DIR="$W/s" "$BIN" -ApplePersistenceIgnoreState YES
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("unguarded.sh:7: launches a bundle ($APP) without cedric_require_check_build $APP first"), "\(out)")
    }

    /// A guard for one bundle does not cover another.
    @Test func aSecondUnguardedBundleFails() throws {
        let (d, paths) = try fixtures(["two.sh": """
            #!/bin/bash
            APP="dist/Owlink.app"
            FROM="$1"
            BIN="$APP/Contents/MacOS/Cedric"
            OLD_BIN="$FROM/Contents/MacOS/Cedric"
            . Scripts/check-env.sh
            cedric_require_check_build "$APP"
            W=$(mktemp -d)
            cedric_isolate "$W"
            export CEDRIC_SESSION_DIR="$W/s"
            "$BIN" -ApplePersistenceIgnoreState YES
            "$OLD_BIN" -ApplePersistenceIgnoreState YES
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("two.sh:12: launches a bundle ($FROM) without cedric_require_check_build $FROM first"), "\(out)")
        #expect(!out.contains("two.sh:11:"), "\(out)")
    }

    /// The same script with both guards, the second after the first launch but before its own.
    @Test func eachBundleGuardedBeforeItsOwnLaunchPasses() throws {
        let (d, paths) = try fixtures(["two-ok.sh": """
            #!/bin/bash
            APP="dist/Owlink.app"
            BIN="$APP/Contents/MacOS/Cedric"
            BIN_ABS=$(cd "$(dirname "$BIN")" && pwd)/Cedric
            OLD_BIN="${1%/}/Contents/MacOS/Cedric"
            . Scripts/check-env.sh
            cedric_require_check_build "$APP"
            W=$(mktemp -d)
            cedric_isolate "$W"
            export CEDRIC_SESSION_DIR="$W/s"
            "$BIN_ABS" -ApplePersistenceIgnoreState YES
            cedric_require_check_build "$1"
            "$OLD_BIN" -ApplePersistenceIgnoreState YES
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 0, "\(out)")
    }

    /// A comment naming CEDRIC_SESSION_DIR sets nothing.
    @Test func aCommentOnlySessionSettingFails() throws {
        let (d, paths) = try fixtures(["comment.sh": """
            #!/bin/bash
            APP="dist/Owlink.app"
            BIN="$APP/Contents/MacOS/Cedric"
            . Scripts/check-env.sh
            cedric_require_check_build "$APP"
            W=$(mktemp -d)
            cedric_isolate "$W"
            # TODO: export CEDRIC_SESSION_DIR="$W/s"
            "$BIN" -ApplePersistenceIgnoreState YES # CEDRIC_SESSION_DIR=x
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("comment.sh:9: launches the app without CEDRIC_SESSION_DIR"), "\(out)")
    }

    /// open(1) goes through Launch Services, which takes no per-launch environment.
    @Test func openingTheAppWithOpenFails() throws {
        let (d, paths) = try fixtures(["open.sh": """
            #!/bin/bash
            APP="dist/Owlink.app"
            open "$APP"
            open -n -a Owlink --args -ApplePersistenceIgnoreState YES
            [ -d "$APP" ] && open -b net.mindtricks.cedric
            env FOO=1 open "cedric://open?path=/tmp/x"
            open -g "$APP"
            open https://example.com
            echo "open $APP"
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        for n in [3, 4, 5, 6, 7] {
            #expect(out.contains("open.sh:\(n): launches Owlink with open(1)"), "line \(n): \(out)")
        }
        #expect(!out.contains("open.sh:8:") && !out.contains("open.sh:9:"), "\(out)")
    }

    /// A Swift launcher: named on the command line, or run from a shell script.
    @Test func aSwiftLauncherMustGuardAndIsolate() throws {
        let launcher = """
            import AppKit
            let cfg = NSWorkspace.OpenConfiguration()
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: CommandLine.arguments[1]), configuration: cfg) { _, _ in }
            // CedricCheckBuild CEDRIC_SESSION_DIR CEDRIC_REPLACE_UNDO_DIR (a comment)
            """
        let (d, paths) = try fixtures(["timer.swift": launcher, "bench.sh": """
            #!/bin/bash
            swift timer.swift dist/Owlink.app
            """, "ok.swift": """
            import AppKit
            let info = NSDictionary(contentsOfFile: "x/Contents/Info.plist")
            guard info?["CedricCheckBuild"] as? Bool == true else { exit(1) }
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.environment = ["CEDRIC_SESSION_DIR": "/tmp/s", "CEDRIC_REPLACE_UNDO_DIR": "/tmp/u"]
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "x"), configuration: cfg) { _, _ in }
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("timer.swift: a Swift launcher does not check the CedricCheckBuild marker"), "\(out)")
        #expect(out.contains("timer.swift: a Swift launcher launches without setting CEDRIC_SESSION_DIR"), "\(out)")
        #expect(out.contains("timer.swift: a Swift launcher launches without setting CEDRIC_REPLACE_UNDO_DIR"), "\(out)")
        #expect(out.contains("bench.sh:2: runs a Swift launcher (timer.swift) that does not check the CedricCheckBuild marker"), "\(out)")
        #expect(!out.contains("ok.swift"), "\(out)")
    }

    /// A release gate must ask for the opt-in before it launches; a
    /// real-launch waiver means nothing outside one.
    @Test func aReleaseGateNeedsTheOptInFirst() throws {
        let (d, paths) = try fixtures(["gate.sh": """
            #!/bin/bash
            # isolation-lint: release-gate (fixture)
            EXE="$1/Contents/MacOS/Cedric"
            "$EXE" -ApplePersistenceIgnoreState YES
            """, "gate-ok.sh": """
            #!/bin/bash
            # isolation-lint: release-gate (fixture)
            . Scripts/check-env.sh
            cedric_require_release_gate
            EXE="$1/Contents/MacOS/Cedric"
            ENV_CLEAN=(env CEDRIC_SESSION_DIR=/tmp/s CEDRIC_REPLACE_UNDO_DIR=/tmp/u)
            # isolation-lint: real-launch the shipped build
            "${ENV_CLEAN[@]}" "$EXE" -ApplePersistenceIgnoreState YES
            """, "waived.sh": """
            #!/bin/bash
            APP="dist/Owlink.app"
            BIN="$APP/Contents/MacOS/Cedric"
            . Scripts/check-env.sh
            cedric_require_check_build "$APP"
            W=$(mktemp -d)
            cedric_isolate "$W"
            export CEDRIC_SESSION_DIR="$W/s"
            ENV_CLEAN=(env)
            # isolation-lint: real-launch as a user does
            "${ENV_CLEAN[@]}" "$BIN"
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("gate.sh:4: a release gate launches before cedric_require_release_gate"), "\(out)")
        #expect(!out.contains("FAIL \(d.path)/gate-ok.sh"), "\(out)")
        #expect(out.contains("allowed \(d.path)/gate-ok.sh:8: real-launch: the shipped build"), "\(out)")
        #expect(out.contains("waived.sh:11: an isolation-lint real-launch marker outside a release gate"), "\(out)")
        #expect(out.contains("waived.sh:11: a launch that strips the environment must set"), "\(out)")
    }

    /// Only release.sh may set OWLINK_RELEASE_GATE, and only for launch-check --release.
    @Test func onlyReleaseShSetsTheReleaseGateOptIn() throws {
        let (d, paths) = try fixtures(["helper.sh": """
            #!/bin/bash
            OWLINK_RELEASE_GATE=1 Scripts/smoke-launch.sh "$1"
            export OWLINK_RELEASE_GATE=1
            """, "release.sh": """
            #!/bin/bash
            run env OWLINK_RELEASE_GATE=1 Scripts/launch-check.sh --release "$APP" --runs 5
            OWLINK_RELEASE_GATE=1 Scripts/launch-check.sh "$APP"
            """])
        defer { try? FileManager.default.removeItem(at: d) }
        let (status, out) = try lint(paths)
        #expect(status == 1)
        #expect(out.contains("helper.sh:2: sets OWLINK_RELEASE_GATE"), "\(out)")
        #expect(out.contains("helper.sh:3: sets OWLINK_RELEASE_GATE"), "\(out)")
        #expect(out.contains("release.sh:3: sets OWLINK_RELEASE_GATE other than on the launch-check.sh --release command"), "\(out)")
        #expect(!out.contains("release.sh:2:"), "\(out)")
    }
}

/// Scripts/check-env.sh's cedric_require_check_build decides from the
/// bundle alone and never runs it: the fixture "Cedric" executables here
/// would leave a file behind if anything ran them.
@Suite(.offPool) struct CheckBuildGuardTests {
    let fm = FileManager.default

    /// An Owlink.app in a fresh folder whose executable records any run.
    func bundle(checkKey: String?, sparkle: Bool = false) throws -> (URL, URL) {
        let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-check-guard-\(UUID().uuidString)")
        let app = d.appendingPathComponent("Owlink.app")
        let macos = app.appendingPathComponent("Contents/MacOS")
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        let ran = d.appendingPathComponent("ran")
        let exe = macos.appendingPathComponent("Cedric")
        try "#!/bin/sh\ntouch '\(ran.path)'\n".write(to: exe, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)
        var plist: [String: Any] = ["CFBundleExecutable": "Cedric"]
        if let checkKey { plist["CedricCheckBuild"] = checkKey == "true" ? true as Any : checkKey as Any }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        if sparkle {
            try fm.createDirectory(at: app.appendingPathComponent("Contents/Frameworks/Sparkle.framework"), withIntermediateDirectories: true)
        }
        return (app, ran)
    }

    /// Sources check-env.sh and calls cedric_require_check_build APP, then
    /// launches APP as a check script would; status and stderr.
    func guardThenLaunch(_ app: URL) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = CheckIsolationLintTests.root
        p.arguments = ["-c", "set -euo pipefail; . Scripts/check-env.sh; cedric_require_check_build \"$1\"; \"$1/Contents/MacOS/Cedric\"", "check", app.path]
        p.environment = ["PATH": "/usr/bin:/bin"]
        let err = Pipe()
        p.standardError = err
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test func aReleaseBundleIsRefusedWithoutRunning() throws {
        for (key, sparkle) in [(nil, false), (nil, true), ("false", false), ("true", true)] as [(String?, Bool)] {
            let (app, ran) = try bundle(checkKey: key, sparkle: sparkle)
            defer { try? fm.removeItem(at: app.deletingLastPathComponent()) }
            let (status, err) = try guardThenLaunch(app)
            #expect(status == 1, "key \(key ?? "absent"), Sparkle \(sparkle)")
            #expect(err.contains("refusing to launch"), "\(err)")
            #expect(!fm.fileExists(atPath: ran.path), "the guard ran the bundle (key \(key ?? "absent"), Sparkle \(sparkle))")
        }
    }

    @Test func aMarkedCheckBundleIsLaunched() throws {
        let (app, ran) = try bundle(checkKey: "true")
        defer { try? fm.removeItem(at: app.deletingLastPathComponent()) }
        let (status, err) = try guardThenLaunch(app)
        #expect(status == 0, "\(err)")
        #expect(fm.fileExists(atPath: ran.path))
    }

    /// Runs a checkout script with a clean environment (no OWLINK_RELEASE_GATE); status and output.
    func script(_ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.currentDirectoryURL = CheckIsolationLintTests.root
        p.arguments = args
        p.environment = ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// launch-check in dev mode probes the bundle only once it is a check build.
    @Test func launchCheckRefusesAnUnmarkedBundleWithoutRunningIt() throws {
        let (app, ran) = try bundle(checkKey: nil)
        defer { try? fm.removeItem(at: app.deletingLastPathComponent()) }
        let (status, out) = try script(["Scripts/launch-check.sh", "--runs", "1", app.path])
        #expect(status == 1, "\(out)")
        #expect(out.contains("refusing to launch"), "\(out)")
        #expect(!fm.fileExists(atPath: ran.path), "launch-check ran an unmarked bundle")
    }

    /// The release gates need OWLINK_RELEASE_GATE=1 and run nothing without it.
    @Test func releaseGatesRefuseWithoutTheOptIn() throws {
        for sparkle in [false, true] {
            let (app, ran) = try bundle(checkKey: nil, sparkle: sparkle)
            defer { try? fm.removeItem(at: app.deletingLastPathComponent()) }
            let (status, out) = try script(["Scripts/launch-check.sh", "--release", "--runs", "1", app.path])
            #expect(status == 1, "\(out)")
            #expect(out.contains("refusing to run a release gate") && out.contains("disposable macOS user account or VM"), "\(out)")
            #expect(!fm.fileExists(atPath: ran.path), "launch-check --release ran the bundle without the opt-in")
        }
        let zip = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-gate-\(UUID().uuidString).zip")
        try Data().write(to: zip)
        defer { try? fm.removeItem(at: zip) }
        let (status, out) = try script(["Scripts/smoke-launch.sh", zip.path])
        #expect(status == 1, "\(out)")
        #expect(out.contains("refusing to run a release gate"), "\(out)")
        #expect(!out.contains("unzipped"), "\(out)")
    }

    /// With the opt-in, launch-check --release still refuses a marked check build, statically.
    @Test func launchCheckReleaseRefusesAMarkedBundleWithoutRunningIt() throws {
        let (app, ran) = try bundle(checkKey: "true")
        defer { try? fm.removeItem(at: app.deletingLastPathComponent()) }
        let (status, out) = try script(["-c", "OWLINK_RELEASE_GATE=1 Scripts/launch-check.sh --release --runs 1 \"$1\"", "t", app.path])
        #expect(status == 1, "\(out)")
        #expect(out.contains("carries CedricCheckBuild=true"), "\(out)")
        #expect(!fm.fileExists(atPath: ran.path), "launch-check --release ran a marked bundle")
    }

    /// release.sh refuses a marked bundle after building, before the first
    /// signature and outside the launch-check switch; and sets the opt-in
    /// on the launch-check call only.
    @Test func releaseShRefusesAMarkedBundleBeforeSigning() throws {
        let text = try String(contentsOf: CheckIsolationLintTests.root.appendingPathComponent("Scripts/release.sh"), encoding: .utf8)
        let code = text.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let refuse = try #require(code.firstIndex { $0.contains("MARKER") && $0.contains("fail") && $0.contains("CedricCheckBuild") })
        let marker = try #require(code.firstIndex { $0.contains("plutil -extract CedricCheckBuild") && $0.contains("$APP/Contents/Info.plist") })
        let build = try #require(code.firstIndex { $0.contains("run Scripts/bundle-app.sh") })
        let sign = try #require(code.firstIndex { $0.contains("run \"${SIGN[@]}\"") })
        let launchSwitch = try #require(code.firstIndex { $0.contains("if [ $LAUNCH_CHECK = 1 ]") })
        #expect(build < marker && marker < refuse && refuse < sign && refuse < launchSwitch)
        let gates = code.filter { $0.contains("OWLINK_RELEASE_GATE") }
        #expect(gates.count == 1 && gates[0].contains("launch-check.sh --release"), "\(gates)")
    }

    /// bundle-app.sh writes the key for a check build only.
    @Test func bundleAppMarksOnlyCheckBuilds() throws {
        let text = try String(contentsOf: CheckIsolationLintTests.root.appendingPathComponent("Scripts/bundle-app.sh"), encoding: .utf8)
        let line = try #require(text.split(separator: "\n").first { $0.contains("CedricCheckBuild") && !$0.hasPrefix("#") })
        #expect(line.contains("$CHECKS = 1") && line.contains("-bool YES"), "\(line)")
    }
}
