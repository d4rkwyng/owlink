import AppKit
import CedricCore

/// CEDRIC_CHECK=git: a temp git repository with a GitHub remote and one
/// committed file; the file opened in the app, edited with key events,
/// then checked: the branch label and dirty dot, the gutter's change bars
/// (marks and pixels), Copy GitHub Link, a commit made outside the app
/// (picked up by the .git watcher), a detached HEAD, Compare with Last
/// Commit, and a file outside any repository.
extension DevChecks {
    static func gitCheck(_ app: AppDelegate) {
        guard GitRunner.executable != nil else {
            print("check: note: no usable git on this Mac (developer tools missing): nothing to check")
            expect(true, "no git: the check is skipped")
            finish()
            return
        }
        let repo = dir.appendingPathComponent("repo")
        try? FileManager.default.createDirectory(at: repo.appendingPathComponent("src"), withIntermediateDirectories: true)
        @discardableResult
        func git(_ args: [String]) -> String {
            let r = GitRunner.run(["-c", "user.name=Cedric Check", "-c", "user.email=check@example.com", "-c", "commit.gpgsign=false"] + args, cwd: repo)
            if r?.status != 0 { print("check: git \(args.joined(separator: " ")) failed: \(r?.text ?? "-")") }
            return r?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let original = (1...10).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let file = write("repo/src/notes.swift", original)
        git(["init", "-q", "-b", "main"])
        git(["add", "."])
        git(["commit", "-qm", "first"])
        git(["remote", "add", "origin", "git@github.com:example/cedric-demo.git"])
        let sha1 = git(["rev-parse", "HEAD"])
        let plain = write("plain.txt", "not in git\n")

        let tab = app.open(file)!
        sized(tab)
        var label: String { tab.statusBar.gitButton.isHidden ? "" : tab.statusBar.gitButton.attributedTitle.string }
        var refreshes = 0, diffs = 0

        /// Waits (up to 8 s) for `cond`, then goes on.
        func wait(_ what: String, _ cond: @escaping () -> Bool) -> (@escaping () -> Void) -> Void {
            { next in
                let start = Date()
                @MainActor func poll() {
                    if cond() { next(); return }
                    if Date().timeIntervalSince(start) > 8 { expect(false, "waited for \(what)"); next(); return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
                }
                poll()
            }
        }
        func menuItem(_ title: String) -> NSMenuItem? {
            var hit: NSMenuItem?
            func walk(_ m: NSMenu) { for i in m.items where hit == nil { if i.title == title { hit = i }; if let s = i.submenu { walk(s) } } }
            NSApp.mainMenu.map(walk)
            return hit
        }
        /// A menu item, validated as AppKit would, then sent.
        func choose(_ title: String) -> Bool {
            guard let item = menuItem(title), let action = item.action else { expect(false, "a menu item \(title)"); return false }
            guard app.validateMenuItem(item) else { return false }
            return NSApp.sendAction(action, to: app, from: item)
        }
        func barColor(line: Int) -> NSColor? {
            let g = tab.gutter
            g.display()
            guard let r = TypingCheck.glyphRects(tab.textView, NSRange(location: tab.lineIndex.starts[line], length: 1)).first else { return nil }
            let y = g.convert(NSPoint(x: 0, y: r.midY), from: tab.textView).y
            return DevHooks.render(g, NSRect(x: g.bounds.width - 4, y: max(0, y - 2), width: 3, height: 4))?.colorAt(x: 3, y: 4)
        }
        let colors = GutterView.GitColors(tab.palette)
        func near(_ c: NSColor?, _ want: NSColor) -> Bool {
            guard let a = c?.usingColorSpace(.sRGB), let b = want.usingColorSpace(.sRGB) else { return false }
            return abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) < 0.3
        }

        let markers = dir.appendingPathComponent("markers")
        try? FileManager.default.createDirectory(at: markers, withIntermediateDirectories: true)
        var hostile: URL?
        var hostileTab: EditorWindowController?
        var offTab: EditorWindowController?
        var hostileOpened = Date.distantFuture
        let savedSetting = UserDefaults.standard.object(forKey: "showGitChanges")
        func restoreSetting() { UserDefaults.standard.set(savedSetting, forKey: "showGitChanges") }
        /// The audit's PoC: every command-running key writes a marker.
        func makeHostileRepo() -> URL {
            let h = dir.appendingPathComponent("hostile")
            try? FileManager.default.createDirectory(at: h.appendingPathComponent("docs"), withIntermediateDirectories: true)
            func hg(_ args: [String]) { _ = GitRunner.run(["-c", "user.name=c", "-c", "user.email=c@example.com", "-c", "commit.gpgsign=false"] + args, cwd: h) }
            let f = write("hostile/docs/README.md", "# hi\n")
            _ = write("hostile/.gitattributes", "*.md filter=evil diff=evil\n")
            hg(["init", "-q", "-b", "main"])
            hg(["add", "."])
            hg(["commit", "-qm", "first"])
            let m = markers.path
            let real = realpath(h.path, nil).map { p -> String in defer { free(p) }; return String(cString: p) } ?? h.path
            _ = write("hostile/.git/evil.inc", "[core]\n\tfsmonitor = \"touch \(m)/inc-fsmonitor; false\"\n[filter \"inc\"]\n\tclean = \"touch \(m)/inc-clean; cat\"\n")
            // Include-only gc hook (GHSA-h2g3): must still mark the repo hostile.
            _ = write("hostile/.git/gc.inc", "[gc]\n\trecentObjectsHook = \"touch \(m)/gc-hook; false\"\n")
            let cfg = h.appendingPathComponent(".git/config")
            var c = (try? String(contentsOf: cfg, encoding: .utf8)) ?? ""
            c += "[core]\n\tfsmonitor = \"touch \(m)/fsmonitor; false\"\n"
            c += "[filter \"evil\"]\n\tclean = \"touch \(m)/clean; cat\"\n\tsmudge = \"touch \(m)/smudge; cat\"\n\tprocess = \"touch \(m)/process\"\n"
            c += "[diff \"evil\"]\n\ttextconv = \"touch \(m)/textconv; cat\"\n"
            c += "[includeIf \"gitdir:\(real)/.git\"]\n\tpath = evil.inc\n"
            c += "[include]\n\tpath = gc.inc\n"
            try? c.write(to: cfg, atomically: true, encoding: .utf8)
            // Stat data and content no longer match the index (as after an unzip).
            try? "# hi\nchanged\n".write(to: f, atomically: true, encoding: .utf8)
            hostileOpened = Date()
            return f
        }

        run([
            sync { focus(tab) },
            wait("the first git refresh") { (tab.gitState?.refreshCount ?? 0) > 0 },
            sync {
                let git = tab.gitState
                expect(git?.repo?.location.workTree.path == repo.standardizedFileURL.path, "finds the repository root from src/",
                       git?.repo?.location.workTree.path ?? "-")
                expect(label == "main", "the status bar shows the branch, no dirty dot", "'\(label)'")
                expect(tab.statusBar.gitButton.accessibilityLabel()?.isEmpty == false, "the git button has a VoiceOver label")
                expect(git?.changes.isEmpty == true, "no change marks for an unedited file")
                expect(git?.relativePath == "src/notes.swift", "the path from the repository root", git?.relativePath ?? "-")
                expect(git?.remote == GitHubRemote(host: "github.com", owner: "example", repo: "cedric-demo"), "the GitHub remote is read")
                refreshes = git?.refreshCount ?? 0
                diffs = git?.diffCount ?? 0
                // Edit with key events: change line 3, add a line after line 5, delete line 8.
                tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[2] + 4, length: 0))
                type("xy")
                let end5 = tab.lineIndex.starts[4] + tab.lineIndex.contentRange(ofLine: 4).length
                tab.textView.setSelectedRange(NSRange(location: end5, length: 0))
                type("\rnew")
                // Original line 8 is line 9 now (index 8).
                tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[8], length: tab.lineIndex.lineLength(8)))
                key("\u{7f}")
            },
            wait("the diff after typing pauses") { (tab.gitState?.diffCount ?? 0) > diffs },
            sync {
                let c = tab.gitState?.changes ?? GitLineChanges()
                print("check: buffer \(tab.text.debugDescription) marks \(c.lines) deleted \(c.deletedBefore.sorted())")
                expect(c.lines == [2: .modified, 5: .added], "a changed line is modified, a new line added", "\(c.lines)")
                expect(c.deletedBefore == [8], "a deleted line leaves a mark where it was", "\(c.deletedBefore.sorted())")
                expect(c == GitLineChanges.compute(base: original, current: tab.text), "the marks match a fresh diff of the buffer")
                expect(label == "main ●", "the dirty dot shows", "'\(label)'")
                expect(near(barColor(line: 2), colors.modified), "the modified bar is drawn in the gutter", "\(String(describing: barColor(line: 2)))")
                expect(near(barColor(line: 5), colors.added), "the added bar is drawn", "\(String(describing: barColor(line: 5)))")
                expect(!near(barColor(line: 0), colors.added) && !near(barColor(line: 0), colors.modified), "no bar on an unchanged line")
                // Lines 3–4 selected: Copy GitHub Link (no upstream: the commit SHA).
                tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[2] + 1, length: tab.lineIndex.starts[4] - tab.lineIndex.starts[2] - 1))
                NSPasteboard.general.clearContents()
                expect(choose("Copy GitHub Link"), "File › Copy GitHub Link is enabled")
                let link = NSPasteboard.general.string(forType: .string) ?? "-"
                expect(link == "https://github.com/example/cedric-demo/blob/\(sha1)/src/notes.swift#L3-L4", "the link names the commit, file and lines", link)
                tab.textView.setSelectedRange(NSRange(location: tab.lineIndex.starts[6], length: 0))
                _ = choose("Copy GitHub Link")
                let one = NSPasteboard.general.string(forType: .string) ?? "-"
                expect(one.hasSuffix("/src/notes.swift#L7"), "the caret's line alone: #L7", one)
            },
            snapshot("git-gutter.png"),
            sync {
                expect(choose("Compare with Last Commit"), "File › Compare › Compare with Last Commit is enabled")
            },
            wait("the compare tab") { app.compareWindows.last?.window?.title == "notes.swift (HEAD) ↔ notes.swift" },
            sync {
                let rows = app.compareWindows.last?.diffView.rows ?? []
                let kinds = rows.map(\.kind)
                expect(kinds.filter { $0 == .changed }.count == 1 && kinds.filter { $0 == .added }.count == 1 && kinds.filter { $0 == .removed }.count == 1,
                       "it compares HEAD's text with the buffer", "\(kinds)")
                app.compareWindows.last?.window?.close()
                tab.window?.makeKeyAndOrderFront(nil)
                focus(tab)
                refreshes = tab.gitState?.refreshCount ?? 0
                key("s", [.command])
            },
            wait("a refresh after saving") { (tab.gitState?.refreshCount ?? 0) > refreshes },
            sync {
                expect(tab.gitState?.status?.changed == true, "after saving, git sees the file changed")
                refreshes = tab.gitState?.refreshCount ?? 0
                // A commit made outside Cedric: the .git watcher notices.
                git(["commit", "-qam", "second"])
            },
            wait("the watcher's refresh after a commit") { (tab.gitState?.refreshCount ?? 0) > refreshes && tab.gitState?.status?.changed == false },
            wait("the marks to clear") { tab.gitState?.changes.isEmpty == true },
            sync {
                expect(label == "main", "after the commit: no dirty dot", "'\(label)'")
                expect(tab.gitState?.status?.headSHA != sha1, "HEAD moved")
                refreshes = tab.gitState?.refreshCount ?? 0
                git(["checkout", "-q", "--detach"])
            },
            wait("the detached HEAD") { tab.gitState?.status?.branch == nil && (tab.gitState?.refreshCount ?? 0) > refreshes },
            sync {
                let short = String(git(["rev-parse", "HEAD"]).prefix(7))
                expect(label == short, "a detached HEAD shows the short SHA", "'\(label)' vs \(short)")
                _ = app.open(plain)
            },
            wait("the plain file's refresh") { (app.tabs.last?.gitState?.refreshCount ?? 0) > 0 },
            sync {
                let p = app.tabs.last!
                expect(p.doc.fileURL?.lastPathComponent == "plain.txt" && p.statusBar.gitButton.isHidden, "a file outside git: no branch label")
                expect(p.gitState?.repo == nil && p.gitState?.changes.isEmpty == true, "and no repository or marks")
                expect(menuItem("Copy GitHub Link").map { !app.validateMenuItem($0) } ?? false, "Copy GitHub Link is disabled there")
                expect(menuItem("Compare with Last Commit").map { !app.validateMenuItem($0) } ?? false, "and Compare with Last Commit")
                hostile = makeHostileRepo()
                hostileTab = app.open(hostile!)
                if let h = hostileTab { sized(h); focus(h) }
            },
            // Security audit H1: a repository whose config runs programs
            // (fsmonitor, clean/smudge filters, a textconv driver, an
            // includeIf'd file) runs nothing, and says git info is off.
            wait("the hostile repo's refresh") { (hostileTab?.gitState?.refreshCount ?? 0) > 0 },
            wait("a moment for anything git might have started") { Date().timeIntervalSince(hostileOpened) > 1.5 },
            sync {
                let h = hostileTab
                expect(h?.gitState?.refused == true, "a repository asking to run commands: git refused")
                let hl = h.map { $0.statusBar.gitButton.isHidden ? "" : $0.statusBar.gitButton.attributedTitle.string } ?? "-"
                expect(hl == "Git info off", "the status bar says Git info off", hl)
                expect(h?.gitState?.changes.isEmpty == true && h?.gitState?.baseText == nil, "no gutter marks there")
                expect(menuItem("Compare with Last Commit").map { !app.validateMenuItem($0) } ?? false, "Compare with Last Commit is off there")
                // Edit and save: refreshes again, still nothing runs.
                h?.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("x")
                key("s", [.command])
                refreshes = h?.gitState?.refreshCount ?? 0
            },
            wait("the refresh after saving there") { (hostileTab?.gitState?.refreshCount ?? 0) > refreshes },
            sync {
                let m = (try? FileManager.default.contentsOfDirectory(atPath: markers.path)) ?? []
                expect(m.isEmpty, "no marker file: none of the repository's programs ran", "\(m.sorted())")
                // The PoC is real: a plain, unprotected git status runs them.
                if let git = GitRunner.executable, let h = hostile {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: git)
                    p.arguments = ["status", "--porcelain"]
                    p.currentDirectoryURL = h.deletingLastPathComponent()
                    p.standardOutput = FileHandle.nullDevice
                    p.standardError = FileHandle.nullDevice
                    try? p.run()
                    p.waitUntilExit()
                    let after = (try? FileManager.default.contentsOfDirectory(atPath: markers.path)) ?? []
                    expect(!after.isEmpty, "control: plain git status there does run them", "\(after.sorted())")
                }
                // The setting off: no git process at all for a new tab.
                Settings.shared.showGitChanges = false
                offTab = app.open(write("repo/src/other.swift", "x\n"))
                if let o = offTab { sized(o); focus(o) }
                hostileOpened = Date()
            },
            wait("a while with the setting off") { Date().timeIntervalSince(hostileOpened) > 2 },
            sync {
                expect(offTab?.gitState?.refreshCount == 0, "Show git changes off: git never ran for the tab",
                       "\(offTab?.gitState?.refreshCount ?? -1)")
                expect(offTab?.statusBar.gitButton.isHidden == true, "and no branch label")
                expect(tab.gitState?.status == nil && tab.statusBar.gitButton.isHidden, "an open tab drops its git info")
                Settings.shared.showGitChanges = true
            },
            wait("git back on") { (offTab?.gitState?.refreshCount ?? 0) > 0 && offTab?.gitState?.status != nil },
            sync {
                restoreSetting()
                expect(offTab?.statusBar.gitButton.isHidden == false, "on again: the branch label is back")
            },
        ])
    }
}
