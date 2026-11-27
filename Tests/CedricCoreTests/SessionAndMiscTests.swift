import Foundation
import Testing
@testable import CedricCore

func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("cedric-test-\(UUID().uuidString)", isDirectory: true)
    return d
}

@Suite struct SessionTests {
    @Test func saveAndRestoreWithUntitledAndDirtyTabs() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        #expect(store.load() == nil)

        let untitled = SessionTab(untitledName: "Untitled 2", hasBuffer: true, language: .markdown, selectionLocation: 3, topLine: 0)
        let dirtyFile = SessionTab(path: "/tmp/notes.txt", hasBuffer: true, encoding: .latin1, lineEnding: .crlf, selectionLocation: 10, selectionLength: 4, topLine: 42)
        let clean = SessionTab(path: "/tmp/clean.swift")
        try store.writeBuffer(untitled.id, text: "# Draft\nnever saved ✓")
        try store.writeBuffer(dirtyFile.id, text: "edited")
        let session = Session(windows: [SessionWindow(tabs: [untitled, dirtyFile], selectedTab: 1, frame: "0 0 800 600 0 0 1440 900"),
                                        SessionWindow(tabs: [clean])], untitledCounter: 2)
        try store.save(session)

        // A new store on the same directory, as after a relaunch or crash.
        let again = SessionStore(directory: dir)
        let restored = try #require(again.load())
        #expect(restored == session)
        #expect(again.readBuffer(untitled.id) == "# Draft\nnever saved ✓")
        #expect(again.readBuffer(dirtyFile.id) == "edited")
        #expect(again.readBuffer(clean.id) == nil)
        #expect(restored.allTabs.count == 3)
    }

    @Test func restoreListSkipsMissingCleanFilesButKeepsBuffersAndUntitledTabs() {
        let missing = SessionTab(path: "/moved/notes.txt")
        let buffered = SessionTab(path: "/moved/draft.txt", hasBuffer: true)
        let existing = SessionTab(path: "/present/readme.txt")
        let untitled = SessionTab(untitledName: "Untitled", hasBuffer: true)
        let tabs = [missing, buffered, existing, untitled]
        let open = SessionRestoreList.openTabs(tabs) { $0 == "/present/readme.txt" }
        #expect(open == [buffered, existing, untitled])
    }

    @Test func reopenPolicyIsOnUnlessOwlinksOwnPreferenceSaysOff() {
        #expect(SessionReopenPolicy.shouldReopen(explicit: true))
        #expect(!SessionReopenPolicy.shouldReopen(explicit: false))
        #expect(SessionReopenPolicy.shouldReopen(explicit: nil), "unset: on")
    }

    /// 0.5.2: macOS's global NSQuitAlwaysKeepsWindows = false no longer
    /// turns reopen off (Fable 5.2 should-fix), and a launch argument
    /// string `-reopenFilesFromLastSession NO` counts (Fable NIT).
    @Test func reopenPreferenceIgnoresTheSystemQuitSettingAndReadsStrings() {
        let (d, name) = TestDefaults.make("cedric-tests-")
        defer { d.removePersistentDomain(forName: name); TestDefaults.remove(name) }
        d.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        #expect(SessionReopenPolicy.explicitPreference(in: d) == nil)
        #expect(SessionReopenPolicy.shouldReopen(in: d), "the system's quit setting doesn't turn it off")
        d.set("NO", forKey: SessionReopenPolicy.key)
        #expect(SessionReopenPolicy.explicitPreference(in: d) == false, "a launch argument is a string")
        #expect(!SessionReopenPolicy.shouldReopen(in: d))
        d.set("YES", forKey: SessionReopenPolicy.key)
        #expect(SessionReopenPolicy.shouldReopen(in: d))
        d.set(false, forKey: SessionReopenPolicy.key)
        #expect(!SessionReopenPolicy.shouldReopen(in: d))
    }

    @Test func reopenOffStillReopensUnsavedTextAndParksTheRest() {
        let clean = SessionTab(path: "/open/readme.txt")
        let draft = SessionTab(path: "/open/draft.txt", hasBuffer: true)
        let untitled = SessionTab(untitledName: "Untitled", hasBuffer: true)
        let other = SessionTab(path: "/open/other.txt")
        let windows = [SessionWindow(tabs: [clean, draft, untitled], selectedTab: 2, frame: "f"),
                       SessionWindow(tabs: [other], selectedTab: 0)]
        let on = SessionReopenPolicy.plan(windows, reopen: true)
        #expect(on.windows == windows && on.park.isEmpty)
        let off = SessionReopenPolicy.plan(windows, reopen: false)
        #expect(off.windows.count == 1, "a window with nothing unsaved doesn't come back")
        #expect(off.windows.first?.tabs == [draft, untitled])
        #expect(off.windows.first?.selectedTab == 1, "the selected tab stays selected")
        #expect(off.windows.first?.frame == "f")
        #expect(off.park == [clean, other], "files go to Reopen Closed Tab")
        #expect(!off.park.contains { $0.hasBuffer }, "unsaved text is never parked")
        let unselected = SessionReopenPolicy.plan([SessionWindow(tabs: [clean, draft], selectedTab: 0)], reopen: false)
        #expect(unselected.windows.first?.selectedTab == 0)
    }

    @Test func policyOffParksOpenTabsOntoTheClosedListAndKeepsBuffers() {
        var closed = [SessionTab(path: "/old/done.txt")]
        let buffered = SessionTab(path: "/open/draft.txt", hasBuffer: true)
        let clean = SessionTab(path: "/open/readme.txt")
        for tab in [buffered, clean] {
            let r = ClosedTabs.push(tab, onto: closed)
            closed = r.list
        }
        #expect(closed.map(\.path) == ["/old/done.txt", "/open/draft.txt", "/open/readme.txt"])
        #expect(closed.first { $0.path == "/open/draft.txt" }?.hasBuffer == true)
    }

    @Test func pruneRemovesOrphanBuffers() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let keep = UUID(), drop = UUID()
        try store.writeBuffer(keep, text: "k")
        try store.writeBuffer(drop, text: "d")
        store.pruneBuffers(keeping: [keep])
        #expect(store.readBuffer(keep) == "k")
        #expect(store.readBuffer(drop) == nil)
    }

    @Test func corruptSessionLoadsAsNil() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: dir.appendingPathComponent("session.json"))
        #expect(SessionStore(directory: dir).load() == nil)
    }

    @Test func launchSetsATruncatedSessionAsideAndRecoversItsBuffers() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let a = SessionTab(untitledName: "Untitled", hasBuffer: true)
        let b = SessionTab(path: "/tmp/edited.txt", hasBuffer: true)
        try store.writeBuffer(a.id, text: "older text")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: store.bufferURL(a.id).path)
        try store.writeBuffer(b.id, text: "newer text")
        try store.save(Session(windows: [SessionWindow(tabs: [a, b])]))
        let file = dir.appendingPathComponent("session.json")
        let whole = try Data(contentsOf: file)
        let truncated = whole.prefix(whole.count / 2)
        try truncated.write(to: file)

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        guard case .recover(let aside, let buffers) = store.loadForLaunch(now: now) else {
            Issue.record("a truncated session must be recovered"); return
        }
        let kept = try #require(aside)
        #expect(kept.lastPathComponent == "session.unreadable-20270115-080000.json")
        #expect(try Data(contentsOf: kept) == truncated)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(buffers == [a.id, b.id])
        #expect(store.readBuffer(a.id) == "older text")
        #expect(store.readBuffer(b.id) == "newer text")

        // A second bad file the same second gets its own name.
        try Data("{".utf8).write(to: file)
        guard case .recover(let second?, _) = store.loadForLaunch(now: now) else { Issue.record("second"); return }
        #expect(second.lastPathComponent == "session.unreadable-20270115-080000-2.json")
        #expect(try Data(contentsOf: kept) == truncated)
    }

    @Test func launchRecoversBuffersWrittenBeforeTheFirstSession() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        #expect(store.loadForLaunch() == .none)
        let id = UUID()
        try store.writeBuffer(id, text: "typed, then the app died")
        #expect(store.loadForLaunch() == .recover(setAside: nil, buffers: [id]))
        try store.save(Session(windows: [SessionWindow(tabs: [SessionTab(id: id, hasBuffer: true)])]))
        guard case .session(let s, _) = store.loadForLaunch() else { Issue.record("a readable session"); return }
        #expect(s.allTabs.map(\.id) == [id])
    }

    @Test func newerVersionIsIgnored() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        var s = Session(windows: [])
        s.version = Session.currentVersion + 1
        try store.save(s)
        #expect(store.load() == nil)
    }

    @Test func environmentOverridesDirectory() {
        #expect(SessionStore.defaultDirectory(environment: ["CEDRIC_SESSION_DIR": "/tmp/x"]).path == "/tmp/x")
        #expect(SessionStore.defaultDirectory(environment: [:]).path.hasSuffix("Application Support/Cedric/Session"))
    }

    @Test func floatOnTopRoundTripsPerWindow() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let floating = SessionWindow(tabs: [SessionTab(path: "/tmp/a.txt")], floatOnTop: true)
        let plain = SessionWindow(tabs: [SessionTab(path: "/tmp/b.txt")])
        let session = Session(windows: [floating, plain])
        try store.save(session)
        let back = try #require(SessionStore(directory: dir).load())
        #expect(back == session)
        #expect(back.windows[0].floatOnTop == true)
        #expect(back.windows[1].floatOnTop == nil)
        let json = try String(contentsOf: dir.appendingPathComponent("session.json"), encoding: .utf8)
        #expect(json.contains("\"floatOnTop\" : true"))
        // Off, and a session from before the key: the key is absent, which decodes as nil.
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("floatOnTop"))
        let legacy = #"{"version":1,"untitledCounter":0,"windows":[{"selectedTab":0,"frame":"0 0 800 600 0 0 1440 900","tabs":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"/tmp/a.txt","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0}]}]}"#
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("session.json"))
        let old = try #require(SessionStore(directory: dir).load())
        #expect(old.windows.count == 1)
        #expect(old.windows[0].floatOnTop == nil)
        #expect(old.windows[0].frame == "0 0 800 600 0 0 1440 900")
    }
}

@Suite struct DockedPreviewSessionTests {
    @Test func savedWithTheTab() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = SessionStore(directory: dir)
        let shown = SessionTab(path: "/tmp/notes.md", language: .markdown, previewShown: true, previewWidth: 420)
        let plain = SessionTab(path: "/tmp/plain.txt")
        let detached = SessionTab(path: "/tmp/other.md", previewDetached: true, previewFrame: "10 20 400 300 0 0 1440 900")
        try store.save(Session(windows: [SessionWindow(tabs: [shown, plain, detached])]))
        let back = try #require(store.load())
        #expect(back.allTabs.map(\.previewShown) == [true, nil, nil])
        #expect(back.allTabs.map(\.previewWidth) == [420, nil, nil])
        #expect(back.allTabs.map(\.previewDetached) == [nil, nil, true])
        let json = try String(contentsOf: dir.appendingPathComponent("session.json"), encoding: .utf8)
        #expect(json.contains("\"previewShown\" : true"))
        #expect(json.contains("\"previewWidth\" : 420"))
        #expect(!json.contains("previewSide"))
        // Not shown: the keys are left out. A detached preview keeps its own fields.
        let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        #expect(!plainJSON.contains("previewShown") && !plainJSON.contains("previewWidth") && !plainJSON.contains("previewSide"))
        let detachedJSON = String(decoding: try JSONEncoder().encode(detached), as: UTF8.self)
        #expect(detachedJSON.contains("previewDetached") && !detachedJSON.contains("previewShown") && !detachedJSON.contains("previewWidth"))
    }

    @Test func olderSessionWithoutTheFieldsStillLoads() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // A 0.4 session: a detached preview, and a tab with neither key.
        // Missing keys decode as nil, which means the docked preview is not shown.
        let old = #"{"version":1,"untitledCounter":0,"windows":[{"selectedTab":0,"tabs":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","path":"/tmp/notes.md","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":2,"previewDetached":true,"previewFrame":"10 20 400 300 0 0 1440 900"},{"id":"7C9E6679-7425-40DE-944B-E07FC1F90AE7","path":"/tmp/plain.txt","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0}]}]}"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("session.json"))
        let loaded = try #require(SessionStore(directory: dir).load())
        #expect(loaded.allTabs.count == 2)
        #expect(loaded.allTabs[0].previewDetached == true)
        #expect(loaded.allTabs[0].previewFrame == "10 20 400 300 0 0 1440 900")
        #expect(loaded.allTabs[0].previewShown == nil && loaded.allTabs[0].previewWidth == nil)
        #expect(loaded.allTabs[1].previewShown == nil && loaded.allTabs[1].previewWidth == nil && loaded.allTabs[1].previewDetached == nil)
        // An explicit false is not "shown" (only true reopens the preview).
        let hidden = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","hasBuffer":false,"encoding":"utf8","lineEnding":"lf","selectionLocation":0,"selectionLength":0,"topLine":0,"previewShown":false}"#
        let tab = try JSONDecoder().decode(SessionTab.self, from: Data(hidden.utf8))
        #expect(tab.previewShown == false && tab.previewWidth == nil)
    }
}

@Suite struct LanguageDetectionTests {
    @Test func byExtensionAndName() {
        #expect(LanguageDetector.language(forFileName: "a.swift") == .swift)
        #expect(LanguageDetector.language(forFileName: "A.PY") == .python)
        #expect(LanguageDetector.language(forFileName: "x.tsx") == .typescript)
        #expect(LanguageDetector.language(forFileName: "c.yml") == .yaml)
        #expect(LanguageDetector.language(forFileName: "Gemfile") == .ruby)
        #expect(LanguageDetector.language(forFileName: ".zshrc") == .shell)
        #expect(LanguageDetector.language(forFileName: "README") == nil)
        #expect(LanguageDetector.language(forFileName: ".hidden") == nil)
    }

    @Test func byShebang() {
        #expect(LanguageDetector.detect(fileName: "run", content: "#!/usr/bin/env python3\nprint(1)") == .python)
        #expect(LanguageDetector.detect(fileName: "run", content: "#!/bin/zsh\necho") == .shell)
        #expect(LanguageDetector.detect(fileName: nil, content: "#!/usr/bin/env -S node --x\n") == .javascript)
        #expect(LanguageDetector.detect(fileName: nil, content: "#!/usr/bin/ruby -w\n") == .ruby)
    }

    @Test func sniffingPastedContent() {
        #expect(LanguageDetector.sniff("{\"a\": [1, 2]}") == .json)
        #expect(LanguageDetector.sniff("<!DOCTYPE html>\n<html></html>") == .html)
        #expect(LanguageDetector.sniff("import SwiftUI\n\nstruct V: View {}") == .swift)
        #expect(LanguageDetector.sniff("from os import path\ndef f():\n    pass") == .python)
        #expect(LanguageDetector.sniff("# Title\n\nSome text\n\n## More") == .markdown)
        #expect(LanguageDetector.sniff("#include <stdio.h>\nint main() {}") == .c)
        #expect(LanguageDetector.sniff("name: x\nversion: 2\nitems:\n  - a") == .yaml)
        #expect(LanguageDetector.sniff("just some words") == .plain)
        #expect(LanguageDetector.sniff("") == .plain)
    }

    @Test func fileNameBeatsContent() {
        #expect(LanguageDetector.detect(fileName: "notes.txt", content: "{\"a\": 1}") == .json) // .txt unknown → sniff
        #expect(LanguageDetector.detect(fileName: "data.md", content: "{\"a\": 1}") == .markdown)
    }
}

@Suite struct ThemeTests {
    @Test func everyThemeMeetsAA() {
        var failures: [String] = []
        for p in EditorPalettes.all {
            for (name, fg, bg) in p.textPairs {
                let r = EditorPalettes.contrast(fg, bg)
                if r < 4.5 { failures.append(String(format: "%@ %.2f", name, r)) }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    /// UX review #3: the Context Bar's icons are tinted from the palette
    /// and must reach WCAG's 3:1 for graphics on the bar in every theme,
    /// off and on.
    @Test func contextBarIconsMeetGraphicsContrast() {
        for p in EditorPalettes.all {
            let off = EditorPalettes.contrast(p.contextBarIcon, p.statusBar)
            let on = EditorPalettes.contrast(p.contextBarIconOn, p.statusBar)
            print(String(format: "contextbar contrast %@: icon %.2f, on %.2f", p.name, off, on))
            #expect(off >= 3, "\(p.name) icon \(off)")
            #expect(on >= 3, "\(p.name) on-state icon \(on)")
        }
    }

    /// The on state must read as different from off, not just as a second grey.
    @Test func contextBarOnStateDiffersFromOff() {
        for p in EditorPalettes.all { #expect(p.contextBarIconOn != p.contextBarIcon, "\(p.name)") }
    }

    @Test func systemFollowsAppearance() {
        #expect(EditorTheme.system.palette(systemIsDark: true).name == "dark")
        #expect(EditorTheme.system.palette(systemIsDark: false).name == "light")
        #expect(EditorTheme.tankard.palette(systemIsDark: false).isDark)
        #expect(EditorTheme.cedric.palette(systemIsDark: true).name == "cedric")
        #expect(!EditorTheme.cedric.palette(systemIsDark: true).isDark)
        #expect(EditorTheme.cedricNight.palette(systemIsDark: false).isDark)
        #expect(EditorPalettes.all.count == EditorTheme.allCases.count - 1) // every theme but System
    }

    @Test func everyTokenKindHasAColour() {
        for p in EditorPalettes.all {
            // (.embeddedCode is drawn in the text colour, by design.)
            for k in TokenKind.allCases where k != .plain && k != .embeddedCode { #expect(p.tokens[k] != nil, "\(p.name) \(k)") }
            #expect(p.color(for: .embeddedCode) == p.foreground)
        }
    }
}

/// What the typing check verifies in pixels, checked here on the palettes:
/// the caret and the selection band must be visible on every theme.
@Suite struct CaretAndSelectionTests {
    @Test func caretVisibleOnBackgroundAndCurrentLine() {
        for p in EditorPalettes.all {
            #expect(EditorPalettes.contrast(p.caret, p.background) >= 3, "\(p.name) caret on background")
            #expect(EditorPalettes.contrast(p.caret, p.currentLine) >= 3, "\(p.name) caret on current line")
        }
    }

    @Test func selectionBandDistinctAndTextReadableOnIt() {
        for p in EditorPalettes.all {
            #expect(EditorPalettes.contrast(p.selection, p.background) >= 1.25, "\(p.name) selection band")
            #expect(EditorPalettes.contrast(p.foreground, p.selection) >= 4.5, "\(p.name) text on selection")
        }
    }

    @Test func foregroundIsNeverTheBackground() {
        for p in EditorPalettes.all {
            #expect(EditorPalettes.contrast(p.foreground, p.background) >= 7, "\(p.name) text")
            for k in TokenKind.allCases where k != .plain {
                #expect(p.color(for: k) != p.background, "\(p.name) \(k)")
            }
        }
    }
}

@Suite struct UntitledNameTests {
    @Test func firstIsPlainUntitled() {
        #expect(UntitledNames.next(open: []) == "Untitled")
    }

    @Test func countsUpWhileOpen() {
        #expect(UntitledNames.next(open: ["Untitled"]) == "Untitled 2")
        #expect(UntitledNames.next(open: ["Untitled", "Untitled 2"]) == "Untitled 3")
    }

    @Test func reusesTheLowestFreeNumber() {
        // Derek's case: earlier untitled tabs closed, the next one isn't "Untitled 3".
        #expect(UntitledNames.next(open: ["Untitled 3"]) == "Untitled")
        #expect(UntitledNames.next(open: ["Untitled", "Untitled 3"]) == "Untitled 2")
        #expect(UntitledNames.next(open: ["Untitled", "Untitled 2", "Untitled 4"]) == "Untitled 3")
    }

    @Test func ignoresOtherNamesAndUsesTheBase() {
        #expect(UntitledNames.next(open: ["notes.md", "Untitled 2"]) == "Untitled")
        #expect(UntitledNames.next(open: ["Sans titre"], base: "Sans titre") == "Sans titre 2")
    }
}
