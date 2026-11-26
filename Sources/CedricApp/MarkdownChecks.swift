import AppKit
import CedricCore

/// In-process checks of Markdown editing, run by Scripts/tools-check.sh
/// like the other DevChecks, with real key events (Return, Tab, ⇧Tab and
/// the menus' key equivalents) and typed text.
///
///   CEDRIC_CHECK=mdlists|mdformat|mdtable|mdpaste|langindent
@MainActor
extension DevChecks {
    static func markdownCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "mdlists": markdownLists(app)
        case "mdformat": markdownFormat(app)
        case "mdtable": markdownTable(app)
        case "mdpaste": markdownPaste(app)
        case "langindent": languageIndent(app)
        default: return markdownPreviewCheck(name, app)
        }
        return true
    }

    /// Where `s` ends in the tab's text; a failed check (not a trap) when
    /// an earlier step left the text without it.
    static func endOf(_ s: String, in tab: EditorWindowController) -> Int? {
        let r = (tab.text as NSString).range(of: s)
        guard r.location != NSNotFound else { expect(false, "the text still holds \(s.debugDescription)", tab.text); return nil }
        return NSMaxRange(r)
    }

    /// Selects `s` in the tab's text (a failed check if it isn't there).
    static func selectText(_ s: String, in tab: EditorWindowController) {
        guard let end = endOf(s, in: tab) else { return }
        tab.textView.setSelectedRange(NSRange(location: end - (s as NSString).length, length: (s as NSString).length))
    }

    /// Puts the caret at the end of the text.
    static func caretAtEnd(_ tab: EditorWindowController) {
        tab.textView.setSelectedRange(NSRange(location: (tab.text as NSString).length, length: 0))
    }

    static func markdownLists(_ app: AppDelegate) {
        let tab = app.open(write("lists.md", "# Shopping\n\n- eggs"))!
        let fence = app.open(write("fence.md", "```\n- in code"))!
        sized(tab)
        let tv = tab.textView
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                caretAtEnd(tab)
                key("\r")
                type("milk")
                expect(tab.text == "# Shopping\n\n- eggs\n- milk", "Return continues a bullet list", tab.text)
                key("\t")
                expect(tab.text == "# Shopping\n\n- eggs\n  - milk", "Tab indents the item under the one above", tab.text)
                backtab()
                expect(tab.text == "# Shopping\n\n- eggs\n- milk", "⇧Tab outdents it", tab.text)
                key("\r")
            },
            sync {
                key("\r")
                expect(tab.text == "# Shopping\n\n- eggs\n- milk\n", "Return on the empty item ends the list", tab.text)
                type("1. one")
                key("\r")
                type("two")
                key("\r")
                type("[ ] three")
            },
            sync {
                key("\r")
                expect(tab.text.hasSuffix("1. one\n2. two\n3. [ ] three\n4. [ ] "), "ordered items count up; a task item continues unchecked", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text.hasSuffix("3. [ ] three"), "one ⌘Z undoes one continuation", tab.text)
                // Return in the middle of the list renumbers what follows.
                let ns = tab.text as NSString
                guard let at = endOf("one", in: tab) else { return }
                tv.setSelectedRange(NSRange(location: at, length: 0))
                key("\r")
                type("new")
                expect(tab.text.hasSuffix("1. one\n2. new\n3. two\n4. [ ] three"), "an inserted item renumbers the rest", tab.text)
            },
            sync {
                key("\t")
                expect(tab.text.hasSuffix("1. one\n   1. new\n2. two\n3. [ ] three"), "Tab nests it and renumbers both levels", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text.hasSuffix("1. one\n2. new\n3. two\n4. [ ] three"), "one ⌘Z undoes the indent and renumbering", tab.text)
            },
            sync {
                // Inside a fence, Return is plain.
                focus(fence)
                caretAtEnd(fence)
                key("\r")
                expect(fence.text == "```\n- in code\n", "inside fenced code Return doesn't continue the list", fence.text)
                key("\t")
                expect(fence.text.hasPrefix("```\n- in code\n") && fence.text != "```\n- in code\n", "and Tab types its usual indent", fence.text)
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            snapshot("mdlists.png"),
            sync {
                // Return in a 100,000-line document: the fence scan is cached
                // per line start, so a Return costs the same at the end as
                // at the top (the first one scans the file once).
                var big = ""
                for k in 0..<34_000 { big += k % 50 == 0 ? "```\ncode\n```\n- item \(k)\n\n" : "Text \(k)\n- item\n\n" }
                big += "- last"
                let bigTab = app.open(write("big.md", big))!
                focus(bigTab)
                let lines = bigTab.lineIndex.lineCount
                var times: [Double] = []
                for k in 0..<12 {
                    caretAtEnd(bigTab)
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    key("\r")
                    times.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                    if k == 0 { expect(bigTab.text.hasSuffix("- last\n- "), "Return continues the last item of a \(lines)-line file", String(bigTab.text.suffix(20))) }
                    key("\u{7f}")
                    key("\u{7f}")
                    key("\u{7f}")
                }
                let warm = times.dropFirst().sorted()
                let median = warm[warm.count / 2]
                // The same text as plain text: what Return costs with no Markdown work.
                let plain = app.open(write("big.txt", big))!
                focus(plain)
                var base: [Double] = []
                for _ in 0..<12 {
                    caretAtEnd(plain)
                    let t0 = DispatchTime.now().uptimeNanoseconds
                    key("\r")
                    base.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                    key("\u{7f}")
                }
                let baseMedian = base.dropFirst().sorted()[(base.count - 1) / 2]
                print(String(format: "check: metric md_return_100k_first_ms=%.2f md_return_100k_median_ms=%.2f plain_return_100k_median_ms=%.2f lines=%d",
                             times[0], median, baseMedian, lines))
                expect(lines >= 100_000, "the file has 100,000 lines", "\(lines)")
                expect(median < 5, "Return at the end of a 100,000-line Markdown file takes under 5 ms (median)", String(format: "%.2f ms", median))
                expect(times[0] < 50, "the first one (which scans the fences once) under 50 ms", String(format: "%.2f ms", times[0]))
            },
        ]
        steps += steps2
        run(steps)
    }

    static func markdownFormat(_ app: AppDelegate) {
        let tab = app.open(write("format.md", "Some words here"))!
        let swift = app.open(write("plain.swift", "let x = 1"))!
        sized(tab)
        let tv = tab.textView
        let general = NSPasteboard.general
        let savedClip = general.string(forType: .string)
        func select(_ s: String) { selectText(s, in: tab) }
        run([
            sync {
                focus(tab)
                select("words")
                key("b", [.command])
                expect(tab.text == "Some **words** here", "⌘B makes the selection bold", tab.text)
                expect(tv.selectedRange() == NSRange(location: 7, length: 5), "and keeps it selected", "\(tv.selectedRange())")
            },
            sync {
                key("b", [.command])
                expect(tab.text == "Some words here", "⌘B again takes the bold off", tab.text)
            },
            sync {
                key("i", [.command])
                expect(tab.text == "Some *words* here", "⌘I italic", tab.text)
                key("i", [.command])
                expect(tab.text == "Some words here", "⌘I again: not *​*words*​*", tab.text)
                key("x", [.command, .shift])
                expect(tab.text == "Some ~~words~~ here", "⇧⌘X strikethrough", tab.text)
                key("x", [.command, .shift])
                key("`", [.control])
                expect(tab.text == "Some `words` here", "⌃` inline code", tab.text)
                key("`", [.control])
            },
            sync {
                general.clearContents()
                general.setString("https://example.com/docs", forType: .string)
                select("here")
                key("k", [.command])
                expect(tab.text == "Some words [here](https://example.com/docs)", "⌘K links the selection to the URL on the clipboard", tab.text)
            },
            sync {
                general.clearContents()
                general.setString("no url", forType: .string)
                select("Some")
                key("k", [.command])
                expect(tab.text.hasPrefix("[Some]() words"), "⌘K without a URL leaves the caret in the ()", tab.text)
                expect(tv.selectedRange() == NSRange(location: 7, length: 0), "caret between the parentheses", "\(tv.selectedRange())")
            },
            sync {
                key("z", [.command])
                expect(tab.text == "Some words [here](https://example.com/docs)", "⌘Z undoes one format command", tab.text)
                // Caret with no selection: the pair, caret inside; typing goes in.
                caretAtEnd(tab)
                key("b", [.command])
                type("x")
                expect(tab.text.hasSuffix(")**x**"), "⌘B at the caret types inside a new pair", tab.text)
            },
            sync {
                // ⌘↩: task boxes.
                tab.textView.string = ""
                tab.textView.insertText("- [ ] milk\n- eggs\nbread", replacementRange: NSRange(location: 0, length: 0))
                tv.setSelectedRange(NSRange(location: 3, length: 0))
                key("\r", [.command])
                expect(tab.text == "- [x] milk\n- eggs\nbread", "⌘↩ checks the box", tab.text)
                expect(tv.selectedRange().location == 3, "the caret stays put", "\(tv.selectedRange())")
            },
            sync {
                tv.setSelectedRange(NSRange(location: 0, length: (tab.text as NSString).length))
                key("\r", [.command])
                expect(tab.text == "- [ ] milk\n- [ ] eggs\n- [ ] bread", "on several lines: unchecks, adds a box to an item, makes a plain line a task", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text == "- [x] milk\n- eggs\nbread", "one ⌘Z undoes it", tab.text)
            },
            sync {
                // Not in other languages.
                focus(swift)
                swift.textView.setSelectedRange(NSRange(location: 4, length: 1))
                let item = menuItem("b", [.command])
                expect(item != nil && !app.validateMenuItem(item!), "Bold is off outside Markdown")
                expect(swift.text == "let x = 1", "and changes nothing there", swift.text)
                general.clearContents()
                if let savedClip { general.setString(savedClip, forType: .string) }
            },
            snapshot("mdformat.png"),
        ])
    }

    static func markdownTable(_ app: AppDelegate) {
        let tab = app.open(write("table.md", "Prices\n\n| Item | 価格 |"))!
        let fenced = app.open(write("fenced.md", "```\n| a | b |\n|---|---|\n| c | d |"))!
        sized(tab)
        let tv = tab.textView
        run([
            sync {
                focus(tab)
                caretAtEnd(tab)
                key("\t")
                expect(tab.text == "Prices\n\n| Item | 価格 |\n| ---- | ---- |\n|      |      |", "Tab after a header builds the delimiter row and a row", tab.text)
                type("tea")
                key("\t")
                type("五百円")
            },
            sync {
                key("\r")
                expect(tab.text == "Prices\n\n| Item | 価格   |\n| ---- | ------ |\n| tea  | 五百円 |\n|      |        |",
                       "Return at the row end lines up the pipes (wide characters count 2) and adds a row", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text == "Prices\n\n| Item | 価格 |\n| ---- | ---- |\n| tea  | 五百円     |", "one ⌘Z undoes the row and the lining up", tab.text)
                backtab()
                expect(tv.selectedRange().length == 3 && (tab.text as NSString).substring(with: tv.selectedRange()) == "tea",
                       "⇧Tab selects the previous cell's text", "\(tv.selectedRange())")
            },
            sync {
                tv.setSelectedRange(NSRange(location: 10, length: 0))
                _ = choose(#selector(AppDelegate.formatTableMenu(_:)))
                expect(tab.text == "Prices\n\n| Item | 価格   |\n| ---- | ------ |\n| tea  | 五百円 |", "Format Table lines it up", tab.text)
            },
            snapshot("mdtable.png", window: tab.window),
            sync {
                // A table in fenced code is left alone.
                focus(fenced)
                fenced.textView.setSelectedRange(NSRange(location: 6, length: 0))
                key("\t")
                expect(fenced.text.hasPrefix("```\n| \ta | b |\n|---|"), "Tab in fenced code types a tab", fenced.text)
                expect(!fenced.text.contains("| --- |"), "the table in the fence isn't reformatted", fenced.text)
            },
            snapshot("mdtable-fenced.png"),
        ])
    }

    /// Paste and drop in Markdown. Uses the general pasteboard (its text is
    /// put back afterwards) and a private drag pasteboard.
    static func markdownPaste(_ app: AppDelegate) {
        let tab = app.open(write("notes/paste.md", "Read the docs\n"))!
        let swift = app.open(write("notes/code.swift", "let a = 1\n"))!
        app.newTab(nil)
        let untitled = app.tabs.last!
        // A picture outside the document's folder, and a text file.
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = rep.representation(using: .png, properties: [:])!
        let pic = dir.appendingPathComponent("elsewhere/my pic.png")
        try? FileManager.default.createDirectory(at: pic.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: pic)
        let inside = dir.appendingPathComponent("notes/local.png")
        try? png.write(to: inside)
        let txt = write("elsewhere/readme.txt", "hello\n")
        let notes = dir.appendingPathComponent("notes")
        sized(tab)
        let tv = tab.textView
        let general = NSPasteboard.general
        let savedClip = general.string(forType: .string)
        let drag = NSPasteboard(name: NSPasteboard.Name("cedric-check-mddrop-\(getpid())"))
        func select(_ s: String) { selectText(s, in: tab) }
        run([
            sync {
                focus(tab)
                general.clearContents()
                general.setString("https://example.com/docs", forType: .string)
                select("docs")
                key("v", [.command])
                expect(tab.text == "Read the [docs](https://example.com/docs)\n", "a URL pasted over a selection makes a link", tab.text)
            },
            sync {
                key("z", [.command])
                expect(tab.text == "Read the docs\n", "one ⌘Z undoes it", tab.text)
                // A plain paste still pastes.
                general.clearContents()
                general.setString("plain", forType: .string)
                select("docs")
                key("v", [.command])
                expect(tab.text == "Read the plain\n", "other text pastes as before", tab.text)
            },
            sync {
                caretAtEnd(tab)
                general.clearContents()
                general.writeObjects([pic as NSURL])
                key("v", [.command])
                let copied = notes.appendingPathComponent("images/my pic.png")
                expect(tab.text.hasSuffix("\n![](images/my%20pic.png)"), "a pasted image file goes in as an image link", tab.text)
                expect(FileManager.default.contentsEqual(atPath: copied.path, andPath: pic.path), "copied into images/ next to the document", copied.path)
            },
            sync {
                general.clearContents()
                general.setData(png, forType: .png)
                key("v", [.command])
                let names = (try? FileManager.default.contentsOfDirectory(atPath: notes.appendingPathComponent("images").path)) ?? []
                let shot = names.first { $0.hasPrefix("image-") && $0.hasSuffix(".png") }
                expect(shot != nil && tab.text.hasSuffix("![](images/\(shot ?? "?"))"), "a pasted bitmap is saved as images/image-….png and linked", "\(names) \(tab.text)")
            },
            sync {
                // "images" swapped for a link out after it was opened: the copy lands in the
                // folder that was checked, and no link goes in (it would lead elsewhere).
                let fm = FileManager.default
                let images = notes.appendingPathComponent("images"), was = notes.appendingPathComponent("was-images")
                let away = dir.appendingPathComponent("mdpaste-away")
                try? fm.createDirectory(at: away, withIntermediateDirectories: true)
                ImageStore.afterOpen = {
                    try? fm.moveItem(at: images, to: was)
                    try? fm.createSymbolicLink(at: images, withDestinationURL: away)
                }
                let before = tab.text
                general.clearContents()
                general.writeObjects([pic as NSURL])
                key("v", [.command])
                ImageStore.afterOpen = nil
                expect(tab.text == before, "a swapped images folder: no link is inserted", tab.text)
                expect(((try? fm.contentsOfDirectory(atPath: away.path)) ?? ["?"]).isEmpty, "nothing is written where the swapped link leads")
                expect(fm.fileExists(atPath: was.appendingPathComponent("my pic-2.png").path), "the copy is in the folder that was checked")
                let sheet = tab.window?.attachedSheet
                expect(sheet != nil, "and the user is told")
                if let sheet { tab.window?.endSheet(sheet) }
                try? fm.removeItem(at: images)
                try? fm.moveItem(at: was, to: images)
                // A folder named like an image, inside the document's folder: not linked.
                let folderPNG = notes.appendingPathComponent("shots.png")
                try? fm.createDirectory(at: folderPNG, withIntermediateDirectories: true)
                general.clearContents()
                general.writeObjects([folderPNG as NSURL])
                key("v", [.command])
                expect(!tab.text.contains("shots.png"), "a folder named x.png in the folder isn't inserted as an image", tab.text)
            },
            sync {
                // Drops: an image inside the document's folder is linked in place; a text file still opens.
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                let before = app.tabs.count
                drag.clearContents()
                drag.writeObjects([inside as NSURL, txt as NSURL])
                let (op, ok) = drop(drag, on: tab)
                expect(op != [] && ok, "the Markdown text takes the drop", "op \(op.rawValue) ok \(ok)")
                _ = before
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                expect(tab.text.contains("![](local.png)"), "a dropped image inside the folder is linked where it is", tab.text)
                expect(!FileManager.default.fileExists(atPath: notes.appendingPathComponent("images/local.png").path), "and not copied")
                expect(app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "readme.txt" }, "the dropped text file opens in a tab")
                expect(!app.tabs.contains { $0.doc.fileURL?.lastPathComponent == "local.png" }, "the image doesn't open as a tab")
                // In code, a dropped image still opens (only Markdown inserts).
                drag.clearContents()
                drag.writeObjects([pic as NSURL])
                _ = drop(drag, on: swift)
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { next() } },
            sync {
                expect(swift.text == "let a = 1\n", "a Swift tab doesn't insert the image", swift.text)
                // Untitled: nothing goes in; a sheet asks to save first.
                focus(untitled)
                _ = choose(#selector(AppDelegate.pickLanguageMenu(_:)), Language.markdown.rawValue)
                expect(untitled.doc.language == .markdown, "the untitled tab is Markdown", untitled.doc.language.rawValue)
                general.clearContents()
                general.writeObjects([pic as NSURL])
                key("v", [.command])
                expect(untitled.text.isEmpty, "an untitled tab inserts nothing", untitled.text)
                let sheet = untitled.window?.attachedSheet
                expect(sheet != nil, "it asks to save first")
                if let sheet { untitled.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
                drag.releaseGlobally()
                general.clearContents()
                if let savedClip { general.setString(savedClip, forType: .string) }
            },
            snapshot("mdpaste.png", window: tab.window),
        ])
    }

    /// YAML and Python indentation, with no default saved in Settings
    /// (the user's own values are put back after).
    static func languageIndent(_ app: AppDelegate) {
        let restore = keepDefaults(["tabWidth", "indentWithTabs"])
        UserDefaults.standard.removeObject(forKey: "indentWithTabs")
        UserDefaults.standard.removeObject(forKey: "tabWidth")
        let yaml = app.open(write("conf.yaml", ""))!
        let py = app.open(write("prog.py", ""))!
        let txt = app.open(write("plain.txt", ""))!
        sized(yaml)
        run([
            sync {
                focus(txt)
                key("\t")
                expect(txt.text == "\t", "plain text with no default saved: Tab still types a tab", txt.text.debugDescription)
                focus(yaml)
                key("\t")
                expect(yaml.text == "  ", "YAML: Tab types 2 spaces, not a tab", yaml.text.debugDescription)
                yaml.textView.string = ""
                type("items:")
                key("\r")
                type("- one")
                key("\r")
                expect(yaml.text == "items:\n  - one\n  - ", "YAML: Return continues a - item", yaml.text.debugDescription)
            },
            sync {
                key("\r")
                expect(yaml.text == "items:\n  - one\n  ", "Return on an empty - item ends the list", yaml.text.debugDescription)
            },
            sync {
                focus(py)
                type("def f(x):")
                key("\r")
                expect(py.text == "def f(x):\n    ", "Python: 4 spaces after :", py.text.debugDescription)
                type("if x:")
                key("\r")
                type("return 1")
                key("\r")
                expect(py.text.hasSuffix("        return 1\n    "), "Return after return steps one level out", py.text.debugDescription)
                key("\t")
                expect(py.text.hasSuffix("return 1\n        "), "Python: Tab types 4 spaces", py.text.debugDescription)
                type("else:")
                expect(py.text.hasSuffix("        return 1\n    else:"), "typing else: lines it up with its if", py.text.debugDescription)
            },
            sync {
                key("z", [.command])
                expect(!py.text.hasSuffix("    else:"), "⌘Z undoes it", py.text.debugDescription)
                restore()
            },
        ])
    }
}
