import Foundation
import Testing

/// Scripts/make-dmg.sh --self-test: makes a DMG from a tiny ad-hoc-signed
/// app and checks it mounts with exactly that app (same files and CDHash)
/// and an Applications symlink to /Applications, and that the check refuses
/// a different app, and that it leaves no temp folder behind. hdiutil
/// only; nothing is launched, no Finder layout.
@Suite(.offPool) struct MakeDMGScriptTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theSelfTestPasses() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [Self.root.appendingPathComponent("Scripts/make-dmg.sh").path, "--self-test"]
        // Its own TMPDIR, to see that the script removes its temp folders.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("owlink-dmg-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env["TMPDIR"] = tmp.path
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        #expect(p.terminationStatus == 0, "\(text)")
        #expect(text.contains("make-dmg.sh self-test: OK"), "\(text)")
        #expect(text.contains("Applications -> /Applications"), "\(text)")
        let left = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        #expect(left.isEmpty, "temp folders left behind: \(left)")
    }
}
