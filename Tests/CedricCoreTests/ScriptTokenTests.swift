import Foundation
import Testing
@testable import CedricCore

/// Scripts/cedric's token(): the real function from the script, run by bash
/// with HOME pointed at a fresh folder.
@Suite(.offPool) struct ScriptTokenTests {
    let fm = FileManager.default

    /// `token_file=` through the end of `token() { … }`, from the script.
    static func tokenFunction() throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Scripts/cedric"), encoding: .utf8)
        let start = try #require(text.range(of: "token_file=\"$HOME"))
        let body = try #require(text.range(of: "\ntoken() {", range: start.upperBound..<text.endIndex))
        let end = try #require(text.range(of: "\n}\n", range: body.upperBound..<text.endIndex))
        return String(text[start.lowerBound..<end.upperBound])
    }

    func home() throws -> String {
        let h = NSTemporaryDirectory() + "cedric-script-token-\(UUID().uuidString)"
        try fm.createDirectory(atPath: h + "/Library/Application Support", withIntermediateDirectories: true)
        return h
    }

    /// Runs `script` (after the token function) under bash; stdout.
    func bash(_ script: String, home: String) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "set -euo pipefail\n" + (try Self.tokenFunction()) + script]
        p.environment = ["HOME": home, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return String(decoding: data, as: UTF8.self)
    }

    func mode(_ path: String) -> Int? {
        (try? fm.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }

    func cedricDir(_ h: String) -> String { h + "/Library/Application Support/Cedric" }

    @Test func madeOnceIntoAPrivateFolderNoTempLeft() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        let t = try bash("token", home: h)
        #expect(t.count == 32 && t.allSatisfy(\.isHexDigit))
        #expect(try bash("token", home: h) == t, "read, not remade")
        #expect(mode(cedricDir(h)) == 0o700)
        #expect(mode(cedricDir(h) + "/cli-token") == 0o600)
        #expect(try fm.contentsOfDirectory(atPath: cedricDir(h)) == ["cli-token"])
        // The app reads what the script made.
        #expect(CLIToken.read(URL(fileURLWithPath: cedricDir(h) + "/cli-token")) == t)
    }

    /// Several runs at once agree on one token: the hard link lets exactly
    /// one of them win, and nobody reads a half-written file.
    @Test func racingRunsAgree() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        // One write per run (token and newline together), so lines can't interleave.
        let out = try bash("for i in 1 2 3 4 5 6 7 8; do (t=$(token); echo \"$t\") & done; wait", home: h)
        let tokens = out.split(separator: "\n").map(String.init)
        #expect(tokens.count == 8)
        #expect(Set(tokens).count == 1 && tokens[0].count == 32)
        #expect(try fm.contentsOfDirectory(atPath: cedricDir(h)) == ["cli-token"])
    }

    /// A token already there (the app's) is kept, never replaced.
    @Test func keepsTheAppsToken() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        let u = URL(fileURLWithPath: cedricDir(h) + "/cli-token")
        let app = try #require(CLIToken.ensure(at: u))
        #expect(try bash("token", home: h) == app)
    }

    /// The app creates its file, then writes it: an empty read waits 50 ms
    /// and reads again.
    @Test func emptyReadIsRetried() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        let f = cedricDir(h) + "/cli-token"
        try fm.createDirectory(atPath: cedricDir(h), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let late = String(repeating: "ab", count: 16)
        // An empty file, filled in place by another process while token()
        // waits. Not "30 ms later" on the wall clock any more: a busy GitHub
        // runner took longer than the 50 ms wait just to start that writer
        // (release run 45208720302: out was ""). Here token()'s `sleep` (a
        // shell function, found before the command) lets the writer go,
        // waits until it has written, then sleeps as asked. A token() that
        // doesn't wait and read again on an empty file still gets "": the
        // writer then never goes, or gives up after 10 s.
        let out = try bash("""
            : > "$token_file"; chmod 600 "$token_file"
            ( i=0; while [ ! -e "$HOME/.waiting" ] && [ $i -lt 1000 ]; do command sleep 0.01; i=$((i+1)); done
              printf '\(late)\\n' >> "$token_file"; : > "$HOME/.written" ) &
            sleep() {
                printf '%s' "$1" > "$HOME/.slept"; : > "$HOME/.waiting"
                local i=0; while [ ! -e "$HOME/.written" ] && [ $i -lt 1000 ]; do command sleep 0.01; i=$((i+1)); done
                command sleep "$@"
            }
            token; wait
            """, home: h)
        #expect(out == late)
        // The app takes about 30 ms to fill the file it made.
        let slept = (try? String(contentsOfFile: h + "/.slept", encoding: .utf8)).flatMap(Double.init) ?? 0
        #expect(slept > 0.03, "waits longer than the app takes to fill its file: \(slept) s")
    }

    /// A Cedric folder an older version left 0755 is tightened to 0700.
    @Test func widerFolderIsTightened() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        try fm.createDirectory(atPath: cedricDir(h), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(mode(cedricDir(h)) == 0o755)
        _ = try bash("token", home: h)
        #expect(mode(cedricDir(h)) == 0o700)
        #expect(mode(cedricDir(h) + "/cli-token") == 0o600)
    }

    /// An empty token older than about 5 s (a run died before filling it)
    /// is replaced; no temp file is left.
    @Test func staleEmptyTokenIsReplaced() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        let f = cedricDir(h) + "/cli-token"
        try fm.createDirectory(atPath: cedricDir(h), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        #expect(fm.createFile(atPath: f, contents: Data(), attributes: [.posixPermissions: 0o600]))
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: f)
        let t = try bash("token", home: h)
        #expect(t.count == 32 && t.allSatisfy(\.isHexDigit))
        #expect(mode(f) == 0o600)
        #expect(try fm.contentsOfDirectory(atPath: cedricDir(h)) == ["cli-token"])
        #expect(CLIToken.read(URL(fileURLWithPath: f)) == t)
    }

    /// The temp file goes even if the run is killed while making it.
    @Test func trapRemovesTheTempFile() throws {
        let h = try home(); defer { try? fm.removeItem(atPath: h) }
        try fm.createDirectory(atPath: cedricDir(h), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        _ = try bash("""
            token_tmp=$(mktemp "$(dirname "$token_file")/.cli-token.XXXXXX")
            exit 0
            """, home: h)
        #expect(try fm.contentsOfDirectory(atPath: cedricDir(h)).isEmpty)
    }
}
