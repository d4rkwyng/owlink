import AppKit
import CedricCore

/// CEDRIC_CHECK=quickopen (Scripts/palette-check.sh): File › Open Quickly…
/// (⌥⌘O) over a folder in the sidebar, with real key events in the search
/// field. Checked: the index leaves out what .gitignore ignores and hidden
/// files; "fs" ranks FolderSidebar.swift first and Return opens it; a new
/// file shows up through the folder watcher (a folder refresh, not a new
/// index); `#` jumps to a Markdown heading; `>` lists commands; ⇧⌘P and
/// ⌥⌘O switch modes and close.
@MainActor
extension DevChecks {
    static func quickOpenCheck(_ app: AppDelegate) {
        let root = dir.appendingPathComponent("qo", isDirectory: true)
        let readme = write("qo/README.md", "# Intro\n\nText.\n\n## Install steps\n\nMore.\n\n## Usage\n\nEnd.\n")
        _ = write("qo/.gitignore", "build/\n*.log\n")
        _ = write("qo/.env", "SECRET=1\n")
        _ = write("qo/Sources/App/FolderSidebar.swift", "// sidebar\n")
        _ = write("qo/Sources/App/offsets.txt", "offsets\n")
        _ = write("qo/Sources/App/debug.log", "log\n")
        _ = write("qo/build/Generated.swift", "// generated\n")
        let tab = app.open(readme)!
        sized(tab)
        var palette: CommandPalette? { CommandPalette.shared }
        var files: QuickOpenFiles? { FolderSidebar.shared?.quickOpenFiles }
        func press(_ chars: String, _ code: UInt16, _ mods: NSEvent.ModifierFlags = []) {
            guard let panel = palette?.panel else { expect(false, "palette panel exists"); return }
            TypingCheck.key(panel, chars, keyCode: code, mods: mods)
        }
        func typeQuery(_ s: String) {
            for c in s {
                switch c {
                case "#": press("#", 20, [.shift])
                case ">": press(">", 47, [.shift])
                case "/": press("/", 44)
                default: press(String(c), keyCodes[Character(c.lowercased())] ?? 0)
                }
            }
        }
        func titles() -> [String] { palette?.shownTitles ?? [] }
        /// Waits (up to 3 s) for `ok`.
        func wait(_ ok: @escaping () -> Bool) -> (@escaping () -> Void) -> Void {
            { next in
                var n = 0
                @MainActor func poll() { if ok() || n > 60 { next() } else { n += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } } } }
                poll()
            }
        }

        run([
            sync {
                focus(tab)
                key("o", [.command, .option])
                expect(palette?.isOpen == true && palette?.mode == .files, "⌥⌘O opens the palette for files")
                expect(titles() == ["Intro", "Install steps", "Usage"], "with no folder: the document's headings", "\(titles())")
                typeQuery("zzz")
                expect(titles().isEmpty && (palette?.empty.stringValue ?? "").hasPrefix("Open a folder"),
                       "and no match says to open a folder", palette?.empty.stringValue ?? "-")
                key("o", [.command, .option])
                expect(palette?.isOpen == false, "⌥⌘O again closes it")
                app.openFolder(root)
            },
            wait { FolderSidebar.shared?.isShown == true },
            sync {
                focus(tab)
                key("o", [.command, .option])
                expect(palette?.isOpen == true, "⌥⌘O opens it over the folder")
            },
            wait { files?.matcher != nil },
            sync {
                print(String(format: "check: quick open index: %d files, built in %.1f ms off the main thread",
                             files?.matcher?.count ?? -1, files?.lastBuildMilliseconds ?? -1))
                let t = Set(titles())
                expect(t.isSuperset(of: ["README.md", "FolderSidebar.swift", "offsets.txt"]), "the folder's files are listed", "\(t)")
                expect(!t.contains("Generated.swift") && !t.contains("debug.log"), "what .gitignore ignores is left out", "\(t)")
                expect(!t.contains(".env") && !t.contains(".gitignore"), "hidden files are left out (as in the sidebar)", "\(t)")
                expect(files?.builds == 1, "one index build", "\(files?.builds ?? -1)")
                typeQuery("fs")
                print("check: quick open 'fs': \(titles())")
                expect(titles().first == "FolderSidebar.swift", "'fs' ranks FolderSidebar.swift first (over offsets.txt)", "\(titles())")
                expect(palette?.shownRows.first?.candidate.path == "qo/Sources/App", "with its folder", palette?.shownRows.first?.candidate.path ?? "-")
                expect(palette?.lastAnnouncement == "\(titles().count) results", "VoiceOver hears the count", palette?.lastAnnouncement ?? "-")
            },
            { next in snapshot("quickopen-files.png", window: CommandPalette.shared?.panel)(next) },
            sync {
                press("\r", 36)
                let opened = app.tabs.first { $0.doc.fileURL?.lastPathComponent == "FolderSidebar.swift" }
                expect(palette?.isOpen == false, "Return closes the palette")
                expect(opened != nil, "Return opened FolderSidebar.swift")
                expect(opened?.window?.firstResponder === opened?.textView, "its text has the keyboard")
                // A new file: the watcher refreshes one folder.
                _ = write("qo/Sources/App/QuickNew.swift", "// new\n")
            },
            wait { files?.matcher?.paths.contains("Sources/App/QuickNew.swift") == true },
            sync {
                expect(files?.matcher?.paths.contains("Sources/App/QuickNew.swift") == true, "a new file is indexed through the folder watcher")
                expect(files?.builds == 1 && (files?.refreshes ?? 0) > 0, "by refreshing its folder, not a new index",
                       "builds \(files?.builds ?? -1), refreshes \(files?.refreshes ?? -1)")
                focus(tab)
                key("o", [.command, .option])
                typeQuery("#inst")
                expect(titles() == ["Install steps"], "'#' searches the Markdown headings", "\(titles())")
                press("\r", 36)
                let line = tab.lineIndex.line(containing: tab.textView.selectedRange().location)
                expect(palette?.isOpen == false && line == 4, "Return jumps to the heading", "line \(line)")
            },
            sync {
                key("o", [.command, .option])
                typeQuery("install")
                expect(titles().contains("Install steps"), "headings follow the files in a file query", "\(titles())")
                press("\u{1b}", 53)
                key("o", [.command, .option])
                typeQuery(">lowercase")
                expect(palette?.shownRows.first?.item != nil && titles().first == "lowercase", "'>' lists the commands", "\(titles().prefix(3))")
                key("p", [.command, .shift])
                expect(palette?.isOpen == true && palette?.mode == .commands && palette?.field.stringValue == "", "⇧⌘P switches it to commands")
                key("o", [.command, .option])
                expect(palette?.isOpen == true && palette?.mode == .files, "⌥⌘O switches it back to files")
                key("o", [.command, .option])
                expect(palette?.isOpen == false, "⌥⌘O closes it")
            },
        ])
    }
}
