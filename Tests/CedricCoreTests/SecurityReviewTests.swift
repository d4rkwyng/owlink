import Foundation
import Testing
@testable import CedricCore

/// The 0.2.1 security review's fixes (CedricCore side).
@Suite(.offPool) struct SecurityReviewTests {
    let fm = FileManager.default

    func folder() throws -> URL {
        let d = tempDir()
        try fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d.resolvingSymlinksInPath()
    }

    func put(_ root: URL, _ rel: String, _ text: String = "x") throws -> URL {
        let u = root.appendingPathComponent(rel)
        try fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: u)
        return u
    }

    // MARK: 1. Dev hooks

    @Test func releaseBuildIgnoresTheDevSwitches() {
        let env = ["PATH": "/usr/bin", "HOME": "/Users/x",
                   "CEDRIC_OPEN": "/Users/x/Documents/secret.txt", "CEDRIC_SNAPSHOT": "/tmp/s.png", "CEDRIC_SNAPSHOT_QUIT": "1",
                   "CEDRIC_SESSION_DIR": "/tmp/x", "CEDRIC_MODELS_DIR": "/tmp/evil", "CEDRIC_CHECK": "tools", "CEDRIC_PERF_OPEN": "/etc/hosts",
                   "CEDRIC_AI_URL": "http://10.0.0.9:1234/v1", "CEDRIC_CLI_TOKEN_FILE": "/tmp/t",
                   "CEDRIC_LLAMA_CHECK": "1", "CEDRIC_NO_RESTORE": "1", "CEDRIC_NO_SESSION_SAVE": "1",
                   "CEDRIC_LAUNCH_METRICS": "1", "CEDRIC_QUIT_AFTER_LAUNCH": "1"]
        let release = DevEnvironment.filter(env, checksEnabled: false)
        #expect(release["PATH"] == "/usr/bin" && release["HOME"] == "/Users/x", "other variables pass")
        #expect(Set(release.keys.filter { $0.hasPrefix("CEDRIC_") }) == DevEnvironment.releaseAllowed,
                "only the path-free launch switches remain")
        for k in DevEnvironment.releaseAllowed { #expect(!k.contains("DIR") && !k.contains("OPEN") && !k.contains("SNAPSHOT")) }
        #expect(DevEnvironment.filter(env, checksEnabled: true) == env, "a check build sees everything")
        // Session.defaultDirectory reads through the filter.
        #expect(!SessionStore.defaultDirectory(environment: release).path.hasPrefix("/tmp/x"))
    }

    // MARK: 2. PDF links

    @Test func pdfLinksAskRevealOrIgnore() throws {
        let d = try folder()
        defer { try? fm.removeItem(at: d) }
        let text = try put(d, "notes.txt")
        for s in ["https://example.com/a?b=1", "http://example.com", "mailto:someone@example.com"] {
            let u = URL(string: s)!
            #expect(PreviewLinkAction.pdfAction(for: u) == .confirmExternal(u), "\(s) asks first")
        }
        // A file, even a text file Cedric could edit, is only revealed.
        #expect(PreviewLinkAction.pdfAction(for: text) == .revealInFinder(text.standardizedFileURL))
        let app = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        #expect(PreviewLinkAction.pdfAction(for: app) == .revealInFinder(app))
        #expect(PreviewLinkAction.pdfAction(for: d.appendingPathComponent("gone.txt")) == .ignore("missing"))
        for (s, scheme) in [("smb://attacker.invalid/share", "smb"), ("x-apple.systempreferences:com.apple.Security", "x-apple.systempreferences"),
                            ("cedric-doc://doc/etc/hosts", "cedric-doc"), ("javascript:alert(1)", "javascript"),
                            ("cedric://open?path=/etc/hosts", "cedric"), ("vscode://file/x", "vscode"), ("https:///nohost", "https")] {
            #expect(PreviewLinkAction.pdfAction(for: URL(string: s)!) == .ignore(scheme), "\(s) is ignored")
        }
    }

    // MARK: 3. Preview folder with JavaScript on

    @Test func scriptPagesGetOnlyImagesFontsAndCSS() throws {
        let d = try folder()
        defer { try? fm.removeItem(at: d) }
        for f in [".env", ".git/config", "notes.txt", "app.js", "data.json", "a.png", "Logo.SVG", "style.css", "fonts/x.woff2",
                  "sub/.hidden/x.png", "sub/pic.jpg", ".ssh/id.png"] { _ = try put(d, f) }
        try fm.createSymbolicLink(atPath: d.appendingPathComponent("innocent.png").path, withDestinationPath: d.appendingPathComponent(".env").path)
        try fm.createSymbolicLink(atPath: d.appendingPathComponent("git.css").path, withDestinationPath: d.appendingPathComponent(".git/config").path)
        func url(_ rel: String) -> URL { URL(string: "cedric-doc://doc" + d.path + "/" + rel)! }
        for ok in ["a.png", "Logo.SVG", "style.css", "fonts/x.woff2", "sub/pic.jpg"] {
            #expect(PreviewFolder.file(for: url(ok), in: d, scriptOn: true) != nil, "\(ok) is served with JS on")
        }
        for no in [".env", ".git/config", "notes.txt", "app.js", "data.json", "sub/.hidden/x.png", ".ssh/id.png", "innocent.png", "git.css"] {
            #expect(PreviewFolder.file(for: url(no), in: d, scriptOn: true) == nil, "\(no) is refused with JS on")
        }
        // JavaScript off: as before, any file inside the folder.
        for f in [".env", "notes.txt", "app.js", "a.png"] { #expect(PreviewFolder.file(for: url(f), in: d, scriptOn: false) != nil) }
        #expect(PreviewFolder.file(for: URL(string: "cedric-doc://doc/etc/hosts")!, in: d, scriptOn: false) == nil)
    }

    // MARK: 4. Markdown on crafted input

    /// Renders on a thread with a main-thread-sized stack (as Copy as HTML
    /// does; the preview's own queue is checked in release builds). Returns
    /// wall-clock seconds, the render thread's CPU seconds, and that
    /// thread's `Timing.slowdown()`: the larger of the two measured just
    /// before and just after the render, since a render of several seconds
    /// may move between fast and slow cores.
    static func timedRender(_ s: String) -> (html: String, seconds: Double, cpu: Double, slowdown: Double) {
        final class Box: @unchecked Sendable { var html = ""; var seconds = 0.0; var cpu = 0.0; var slowdown = 1.0 }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let t = Thread {
            let before = Timing.slowdown()
            let start = Date(), cpuStart = Timing.threadCPU()
            box.html = Markdown.render(s)
            box.cpu = Timing.threadCPU() - cpuStart
            box.seconds = Date().timeIntervalSince(start)
            box.slowdown = max(before, Timing.slowdown())
            done.signal()
        }
        t.stackSize = 16 << 20
        t.start()
        done.wait()
        return (box.html, box.seconds, box.cpu, box.slowdown)
    }

    /// Generous: a debug build on a loaded CI runner. Before the fix these
    /// took 2–45 s in a release build.
    static let bound = 5.0

    @Test func bracketsAndLinkScansAreLinear() {
        let n = 20_000
        for (name, s) in [("[ ]", String(repeating: "[", count: n) + String(repeating: "]", count: n)),
                          ("[a](", String(repeating: "[a](", count: n)),
                          ("[a](<", String(repeating: "[a](<", count: n)),
                          ("[^", String(repeating: "[^", count: n)),
                          ("[a][", String(repeating: "[a][", count: n)),
                          ("![", String(repeating: "![", count: n)),
                          ("<", String(repeating: "<", count: 2 * n)),
                          ("<a", String(repeating: "<a", count: n) + ">"),
                          ("url)", "http://a" + String(repeating: ")", count: 2 * n))] {
            let r = Self.timedRender(s)
            #expect(r.seconds < Self.bound, "\(name) × \(n): \(r.seconds) s")
        }
    }

    @Test func emphasisRunsAreLinear() {
        for (name, s) in [("*a", String(repeating: "*a", count: 40_000)), ("**a", String(repeating: "**a", count: 40_000)),
                          ("~~a", String(repeating: "~~a", count: 40_000)), ("_a", String(repeating: "_a", count: 40_000))] {
            let r = Self.timedRender(s)
            #expect(r.seconds < Self.bound, "\(name): \(r.seconds) s")
        }
        // Still CommonMark: nesting and the rule of three as before.
        #expect(Markdown.render("**bold *mix***") == "<p data-line=\"0\"><strong>bold <em>mix</em></strong></p>\n")
        #expect(Markdown.render("*a **b** c*") == "<p data-line=\"0\"><em>a <strong>b</strong> c</em></p>\n")
    }

    @Test func deepNestingIsCappedAndQuick() {
        // 2 000 levels of nested list (45 s before), and quotes.
        let list = (0..<2000).map { String(repeating: "  ", count: $0) + "- item\($0)" }.joined(separator: "\n")
        let r = Self.timedRender(list)
        // 4 MB of input: about 0.7 s in a release build, several in a debug one.
        // The render thread's CPU time, scaled by the slowdown measured on
        // that thread (see `Timing`), not the wall clock: on a slow macos-26
        // runner the wall clock reached 42 s (run 45258714905). The 30 s
        // budget is unchanged. The wall clock keeps a wide bound against a
        // blow-up; the uncapped renderer took 45 s in a release build.
        let scaled = r.cpu / r.slowdown
        #expect(scaled < 30, "2 000-deep list: \(scaled) s scaled (\(r.cpu) s CPU, slowdown \(r.slowdown)×, wall \(r.seconds) s)")
        #expect(r.seconds < 120, "2 000-deep list: \(r.seconds) s wall")
        let uls = r.html.components(separatedBy: "<ul").count - 1
        #expect(uls == MarkdownRenderer.maxNesting + 1, "lists nest \(MarkdownRenderer.maxNesting) deep, then text: \(uls)")
        #expect(r.html.contains("item1999"), "the deeper items are still shown, as text")
        let quotes = Self.timedRender(String(repeating: ">", count: 10_000) + " deep")
        #expect(quotes.seconds < Self.bound && quotes.html.contains("deep"))
        #expect(quotes.html.components(separatedBy: "<blockquote").count - 1 == MarkdownRenderer.maxNesting + 1)
        let images = Self.timedRender(String(repeating: "![", count: 5000) + "x" + String(repeating: "](u)", count: 5000))
        #expect(images.seconds < Self.bound && images.html.contains("<img"), "5 000 nested images")
    }

    // MARK: 5. The owl's search_document

    @Test func catastrophicRegexIsStopped() {
        let text = (0..<200).map { _ in String(repeating: "a", count: 60) + "!" }.joined(separator: "\n")
        let snap = OwlDocumentSnapshot(text: text, generation: 1, selection: NSRange(location: 0, length: 0), fileName: "x.txt", language: "plain")
        let start = Date()
        let r = OwlTools.run(OwlToolCall(name: "search_document", arguments: .object(["query": .string("(a+)+$"), "regex": .bool(true)])), on: snap)
        let took = Date().timeIntervalSince(start)
        #expect(!r.ok && r.text.contains("too long"), "\(r.text)")
        #expect(took < 3, "stopped near the time limit: \(took) s")
        let long = OwlTools.run(OwlToolCall(name: "search_document", arguments: .object(["query": .string(String(repeating: "a", count: 150)), "regex": .bool(true)])), on: snap)
        #expect(!long.ok && long.text.contains("too long"), "a long regex is refused")
        let plain = OwlTools.run(OwlToolCall(name: "search_document", arguments: .object(["query": .string("aaa!")])), on: snap)
        #expect(plain.ok && plain.text.contains("1|"), "plain searches still work")
    }

    // MARK: 7. Replace in Files: a folder swapped for a link

    @Test func writeRefusesAFolderSwappedForALink() throws {
        let root = try folder(), outside = try folder()
        defer { try? fm.removeItem(at: root); try? fm.removeItem(at: outside) }
        let target = try put(root, "sub/deeper/file.txt", "inside\n")
        let victim = try put(outside, "deeper/file.txt", "outside\n")
        // Swap sub/ for a link to the outside folder after the checks.
        try fm.removeItem(at: root.appendingPathComponent("sub"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("sub").path, withDestinationPath: outside.path)
        #expect(throws: (any Error).self) { try FileReplace.atomicWrite(Data("pwned\n".utf8), to: target, mode: 0o644, root: root) }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "outside\n", "nothing written outside the folder")
        // A file in a real folder is written, mode kept, no temp left.
        let ok = try put(root, "real/file.txt", "old\n")
        chmod(ok.path, 0o640)
        try FileReplace.atomicWrite(Data("new\n".utf8), to: ok, mode: 0o640, root: root)
        #expect(try String(contentsOf: ok, encoding: .utf8) == "new\n")
        var st = stat()
        #expect(stat(ok.path, &st) == 0 && st.st_mode & 0o777 == 0o640)
        #expect(try fm.contentsOfDirectory(atPath: ok.deletingLastPathComponent().path) == ["file.txt"])
        // The file itself swapped for a link: refused on the folder descriptor.
        try fm.removeItem(at: ok)
        try fm.createSymbolicLink(atPath: ok.path, withDestinationPath: victim.path)
        #expect(throws: (any Error).self) { try FileReplace.atomicWrite(Data("pwned\n".utf8), to: ok, mode: 0o644, root: root) }
        #expect(try String(contentsOf: victim, encoding: .utf8) == "outside\n")
        // Not under the root at all: refused.
        #expect(throws: (any Error).self) { try FileReplace.atomicWrite(Data("x".utf8), to: victim, mode: 0o644, root: root) }
    }

    // MARK: 8. Backups and closed tabs

    @Test func sessionAndReplaceCopiesAreNotBackedUp() throws {
        let d = try folder()
        defer { try? fm.removeItem(at: d) }
        let store = SessionStore(directory: d.appendingPathComponent("Session"))
        try store.save(Session(windows: []))
        let s = try d.appendingPathComponent("Session").resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(s.isExcludedFromBackup == true, "the session folder is excluded from Time Machine")
        let undo = ReplaceUndoStore(root: d.appendingPathComponent("ReplaceUndo"))
        _ = try undo.begin(query: ReplaceQuery(query: "a", template: "b"))
        let u = try d.appendingPathComponent("ReplaceUndo").resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(u.isExcludedFromBackup == true, "Replace in Files' originals too")
    }

    @Test func closedTabTextHasALimit() {
        let now = Date()
        func tab(_ n: String, dirty: Bool = true) -> SessionTab { SessionTab(untitledName: n, hasBuffer: dirty) }
        // Closed 31 days ago: goes, with its text; 29 days: stays.
        var old = tab("old"); old.closed = now.addingTimeInterval(-31 * 86_400)
        var recent = tab("recent"); recent.closed = now.addingTimeInterval(-29 * 86_400)
        let legacy = tab("legacy")  // a 0.2.0 session: no date
        let r = ClosedTabs.expire([old, recent, legacy], now: now)
        #expect(r.list.map(\.untitledName) == ["recent", "legacy"] && r.dropped.map(\.untitledName) == ["old"])
        #expect(r.list.last?.closed == now, "an undated tab is dated now, so it goes 30 days later")
        // Pushing dates the tab; past unsavedLimit the oldest unsaved goes.
        var list: [SessionTab] = []
        var dropped: [SessionTab] = []
        for k in 0..<(ClosedTabs.unsavedLimit + 3) {
            let p = ClosedTabs.push(tab("u\(k)"), onto: list, now: now)
            list = p.list
            dropped += p.dropped
        }
        #expect(list.count == ClosedTabs.unsavedLimit && list.allSatisfy { $0.closed == now })
        #expect(dropped.map(\.untitledName) == ["u0", "u1", "u2"])
    }

    /// 0.2.1 review M4: a session that runs for weeks expires closed tabs
    /// when the next one is pushed, not only at the next launch.
    @Test func pushExpiresOldClosedTabs() {
        let now = Date()
        func tab(_ n: String, dirty: Bool = true) -> SessionTab { SessionTab(untitledName: n, hasBuffer: dirty) }
        // Closed on day 0 and day 2 of one run; the app stays open, and a
        // tab closed on day 31 pushes the day-0 one out.
        let day0 = now.addingTimeInterval(-31 * 86_400)
        var list = ClosedTabs.push(tab("day0"), onto: [], now: day0).list
        list = ClosedTabs.push(tab("day2"), onto: list, now: day0.addingTimeInterval(2 * 86_400)).list
        let d31 = ClosedTabs.push(tab("day31"), onto: list, now: now)
        #expect(d31.list.map(\.untitledName) == ["day2", "day31"] && d31.dropped.map(\.untitledName) == ["day0"])
        list = [tab("a31"), tab("b29"), tab("c40", dirty: false)]
        list[0].closed = now.addingTimeInterval(-31 * 86_400)
        list[1].closed = now.addingTimeInterval(-29 * 86_400)
        list[2].closed = now.addingTimeInterval(-40 * 86_400)
        let p = ClosedTabs.push(tab("new"), onto: list, now: now)
        #expect(p.list.map(\.untitledName) == ["b29", "new"])
        #expect(p.dropped.map(\.untitledName) == ["a31", "c40"], "dropped, so the caller deletes a31's unsaved text")
        // The 100-tab rule still holds at push, together with the age rule.
        var many: [SessionTab] = []
        for k in 0..<ClosedTabs.unsavedLimit {
            var t = tab("u\(k)")
            t.closed = now.addingTimeInterval(k < 5 ? -31 * 86_400 : -86_400)
            many.append(t)
        }
        let q = ClosedTabs.push(tab("last"), onto: many, now: now)
        #expect(q.list.count == ClosedTabs.unsavedLimit - 4 && q.dropped.count == 5, "\(q.list.count) \(q.dropped.count)")
        #expect(q.list.last?.untitledName == "last")
        // An undated tab (from a 0.2.0 session, never restored through expire) is dated, not dropped.
        let r = ClosedTabs.push(tab("new2"), onto: [tab("legacy")], now: now)
        #expect(r.list.map(\.untitledName) == ["legacy", "new2"] && r.list.first?.closed == now)
    }

    // MARK: 9. The CLI token's hand-off

    @Test func authHandoffIsReadOnceAndMustBePrivate() throws {
        let tmp = NSTemporaryDirectory()
        // inspect() wants 6+ letters/digits after the prefix: fixed letters
        // (a random hex slice can have too few) plus the pid for uniqueness.
        let good = tmp + "cedric-auth.tGoodAuthA\(getpid())"
        try PrivateDirectory.writePrivateFile(Data("0123456789abcdef0123456789abcdef\n".utf8), to: URL(fileURLWithPath: good))
        #expect(CLIHandoff.takeAuth(good) == "0123456789abcdef0123456789abcdef")
        #expect(!fm.fileExists(atPath: good), "deleted once read")
        #expect(CLIHandoff.takeAuth(good) == nil, "and good once only")
        let loose = tmp + "cedric-auth.LLooseAuthB\(getpid())"
        fm.createFile(atPath: loose, contents: Data("0123456789abcdef0123456789abcdef\n".utf8), attributes: [.posixPermissions: 0o644])
        #expect(CLIHandoff.takeAuth(loose) == nil, "a file others can read is refused")
        try? fm.removeItem(atPath: loose)
        #expect(CLIHandoff.takeAuth("/etc/cedric-auth.abcdef") == nil, "only in the user's temp folder")
    }

    @Test func tokenRotates() throws {
        let d = try folder()
        defer { try? fm.removeItem(at: d) }
        let url = d.appendingPathComponent("Cedric/cli-token")
        let first = try #require(CLIToken.ensure(at: url))
        let second = try #require(CLIToken.rotate(at: url))
        #expect(first != second && CLIToken.read(url) == second && second.count == 32)
        var st = stat()
        #expect(stat(url.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(try fm.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["cli-token"], "no temp file left")
    }

    /// Scripts/cedric's send(): the token is in a 0600 file, not on `open`'s
    /// command line (other users can read argv with ps).
    @Test func scriptKeepsTheTokenOffTheCommandLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Scripts/cedric"), encoding: .utf8)
        func function(_ name: String) throws -> String {
            let start = try #require(text.range(of: "\n\(name)() {"))
            let end = try #require(text.range(of: "\n}\n", range: start.upperBound..<text.endIndex))
            return String(text[start.lowerBound..<end.upperBound])
        }
        let urlencode = String(try #require(text.split(separator: "\n").first { $0.hasPrefix("urlencode()") }))
        let d = try folder()
        defer { try? fm.removeItem(at: d) }
        let token = "feedfacefeedfacefeedfacefeedface"
        let script = """
        set -euo pipefail
        tmpdir=\(d.path); DRY=""; TOKEN=\(token); TARGET=(-a Owlink)
        open() { printf '%s\\n' "$@" > \(d.path)/argv; }
        \(urlencode)
        \(try function("send"))
        send "cedric://open?path=/tmp/x.txt"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", script]
        p.environment = ["PATH": "/usr/bin:/bin"]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let argv = try String(contentsOf: d.appendingPathComponent("argv"), encoding: .utf8)
        #expect(!argv.contains(token) && !argv.contains("token="), "the token isn't on the command line: \(argv)")
        let auth = try #require(argv.range(of: "&auth=").map { String(argv[$0.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines) })
        let path = try #require(auth.removingPercentEncoding)
        #expect(path.hasPrefix(d.path + "/cedric-auth."))
        var st = stat()
        #expect(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o600, "the hand-off file is owner-only")
        #expect(try String(contentsOfFile: path, encoding: .utf8) == token + "\n")
    }

    // MARK: 11, 12. Scrubber and prompts

    @Test func scrubberRemovesHandlersInAnyTagShape() {
        for hostile in ["<svg/onload=alert(1)>", "<svg onload=alert(1)>", "<a href=\"x\"onclick=\"alert(1)\">x</a>",
                        "<img alt=\"a>b\" onerror=alert(1) src=x>", "<IMG SRC=x ONERROR='alert(1)'>", "<div\tonmouseover=alert(1)>",
                        "<img src=x onerror\n=\nalert(1)>"] {
            let out = HTMLScrub.noScript(hostile)
            #expect(!out.lowercased().contains("alert(1)") || !out.lowercased().contains("on"), "\(hostile) → \(out)")
            #expect(out.range(of: #"(?i)on[a-z]+\s*="#, options: .regularExpression) == nil, "\(hostile) → \(out)")
        }
        // Text between tags is left alone, and so are ordinary attributes.
        #expect(HTMLScrub.noScript("<p>turn the oven on=hot</p>") == "<p>turn the oven on=hot</p>")
        #expect(HTMLScrub.noScript("<a href=\"x\" title=\"y\">z</a>") == "<a href=\"x\" title=\"y\">z</a>")
    }

    @Test func promptsShowHiddenCharactersAsEscapes() {
        let tricky = "/Users/me/\u{202E}txt.exe\u{202C}/x\u{200B}y\u{0007}\n.ssh"
        let shown = PromptText.visible(tricky)
        #expect(shown == "/Users/me/<U+202E>txt.exe<U+202C>/x<U+200B>y<U+0007><U+000A>.ssh")
        #expect(PromptText.visible("/Users/me/Notes ✓ 日本.md") == "/Users/me/Notes ✓ 日本.md", "ordinary text is unchanged")
        #expect(PromptText.visible("a\u{2066}b\u{2069}\u{FEFF}") == "a<U+2066>b<U+2069><U+FEFF>")
    }
}
