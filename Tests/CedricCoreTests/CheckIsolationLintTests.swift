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
            W=$(mktemp -d)
            . Scripts/check-env.sh
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
}
