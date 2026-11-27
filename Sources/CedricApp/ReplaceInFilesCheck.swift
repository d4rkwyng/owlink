import AppKit
import CedricCore

/// CEDRIC_CHECK=replaceinfiles (Scripts/tools-check.sh). A temp tree with
/// a git-ignored folder, a binary, a 21 MB file, a mixed-ending file, a
/// CRLF file (mode 0640), a Latin-1 file, and one file open in a tab with
/// unsaved typing. Drives Edit › Replace in Files… with its shortcut, types
/// the query and replacement as key events, previews, unchecks a file and
/// one match with mouse clicks, clicks Replace All (slowed down: the tab
/// is edited at once, the files are written off the main thread with
/// progress, controls and undo locked meanwhile), then Edit › Undo
/// Replace in Files; checks the bytes on disk and the tab's text at each
/// step.
/// Set by a main-queue block that ran while ReplaceInFiles.writing was true:
/// the UI's run loop turned during the background writes.
@MainActor private var replaceTickedWhileWriting = false

@MainActor
extension DevChecks {
    static func replaceInFilesCheck(_ app: AppDelegate) {
        let root = dir.appendingPathComponent("rif").resolvingSymlinksInPath()
        ReplaceInFiles.store = ReplaceUndoStore(root: dir.appendingPathComponent("replace-undo"))
        func put(_ rel: String, _ data: Data) -> URL {
            let u = root.appendingPathComponent(rel)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: u)
            return u
        }
        _ = put(".git/HEAD", Data("ref: refs/heads/main\n".utf8))
        _ = put(".gitignore", Data("ignored/\n".utf8))
        let ignored = put("ignored/x.txt", Data("owl ignored\n".utf8))
        _ = put("blob.bin", Data("owl".utf8) + Data([0, 1, 2, 0]))
        _ = put("huge.log", Data("owl ".utf8) + Data(repeating: 0x6E, count: 21 * 1024 * 1024))
        let originals: [String: Data] = [
            "crlf.txt": Data("owl one\r\nowl two\r\n".utf8),
            "latin.txt": "café owl\n".data(using: .isoLatin1)!,
            "partial.txt": Data("owl A owl B\n".utf8),
            "unchecked.txt": Data("owl stays\n".utf8),
            "mixed.txt": Data("owl\r\nowl\n".utf8),
            "open.txt": Data("owl disk\n".utf8),
        ]
        var url: [String: URL] = [:]
        for (k, v) in originals { url[k] = put(k, v) }
        chmod(url["crlf.txt"]!.path, 0o640)
        func bytes(_ k: String) -> Data? { try? Data(contentsOf: url[k]!) }
        func mode(_ k: String) -> mode_t { var st = stat(); stat(url[k]!.path, &st); return st.st_mode & 0o7777 }

        let tab = app.open(url["open.txt"]!)!
        sized(tab)
        tab.window?.setContentSize(NSSize(width: 1300, height: 760))
        var panel: FindInFilesPanel { app.findInFiles! }
        func row(_ path: String, line: Int? = nil) -> Int {
            for r in 0..<panel.table.numberOfRows {
                guard let n = panel.table.item(atRow: r) as? ResultNode, n.relativePath == path else { continue }
                if line == nil, n.kind != .match { return r }
                if let line, n.kind == .match, n.edit?.line == line || n.result?.line == line { return r }
            }
            return -1
        }
        /// A real click on the check box in row `r`.
        func clickBox(_ r: Int) -> NSButton? {
            guard r >= 0, let cell = panel.table.view(atColumn: 0, row: r, makeIfNecessary: true) as? ResultCell, let box = cell.box else { return nil }
            panel.table.scrollRowToVisible(r)
            click(box, at: NSPoint(x: box.bounds.midX, y: box.bounds.midY))
            return box
        }

        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                // Unsaved typing in the open tab: the replace must edit this buffer, not the file behind it.
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                type("owl ")
                expect(tab.text == "owl owl disk\n" && tab.doc.isDirty, "typing made the open tab dirty", tab.text.debugDescription)
                expect(menuItem(action: #selector(AppDelegate.undoReplaceInFilesMenu(_:))).map { !app.validateMenuItem($0) } == true,
                       "Undo Replace in Files is disabled before any replace")
            },
            sync {
                key("f", [.command, .option, .shift])
                if app.findInFiles?.isShown != true {
                    // The macOS 15 VM (app active) sometimes drops the synthetic ⌥⇧⌘F; a real one works there.
                    print("check: note: synthetic ⌥⇧⌘F not taken; sending Replace in Files…'s action")
                    app.replaceInFilesMenu(nil)
                }
                let p = app.findInFiles
                expect(p?.isShown == true && p?.window === tab.window, "⌥⇧⌘F docks the panel")
                expect(p?.replaceMode == true && p?.replaceField.superview?.isHidden == false, "…in replace mode, the Replace field shown")
                expect(p?.previewButton.isHidden == false, "Preview Replace… is shown")
                p?.folderField.stringValue = root.path
                expect(p.map { (tab.window?.firstResponder as? NSView)?.isDescendant(of: $0) == true } == true, "the query field has focus")
            },
            sync {
                expect(!panel.previewButton.isEnabled, "Preview Replace… is off while the query is empty")
                type("owl")
            },
            sync {
                expect(panel.queryField.stringValue == "owl", "typed query reached the field", panel.queryField.stringValue)
                // Typing (not only Return or a search) re-validates the buttons.
                expect(panel.previewButton.isEnabled, "typing a query in a fresh panel enables Preview Replace…")
                tab.window?.makeFirstResponder(panel.replaceField)
                type("hoot")
                expect(panel.replaceField.stringValue == "hoot", "typed replacement reached the field", panel.replaceField.stringValue)
            },
            { next in
                // Return in the Replace field: search, then the preview.
                panel.onPreviewReady = { panel.onPreviewReady = nil; next() }
                key("\r")
            },
            sync {
                let p = panel
                expect(p.previewing, "Return in the Replace field shows the preview", p.status.stringValue)
                guard let plan = p.plan else { return }
                let files = plan.files.map(\.relativePath).sorted()
                print("check: preview files \(files), skipped \(plan.skipped.map { "\($0.relativePath):\($0.reason)" })")
                expect(files == ["crlf.txt", "latin.txt", "open.txt", "partial.txt", "unchecked.txt"],
                       "preview: the five replaceable files (not the ignored, binary, 21 MB or mixed-ending ones)", "\(files)")
                expect(!p.results.contains { $0.url.path.hasPrefix(root.appendingPathComponent("ignored").path) }, "the git-ignored folder isn't searched")
                expect(plan.files.first { $0.relativePath == "open.txt" }?.disk == nil, "the open tab is planned from its unsaved text")
                expect(plan.replacementCount == 8, "8 replacements planned", "\(plan.replacementCount)")
                let s = p.summary.stringValue
                expect(!p.summary.isHidden && s.contains("8 replacements in 5 files") && s.contains("1 binary") && s.contains("1 over 20 MB")
                       && s.contains("1 mixed line endings"), "the summary counts replacements and every skip", s)
                // The list and the summary agree: every skipped file, with its reason.
                let listed = p.skippedFiles.map { "\($0.relativePath):\($0.reason)" }
                expect(listed == ["blob.bin:binary", "huge.log:tooLarge", "mixed.txt:mixedLineEndings"], "every skipped file is listed with its reason", "\(listed)")
                expect(row("Skipped (3)") >= 0 && ["blob.bin", "huge.log", "mixed.txt"].allSatisfy { row($0) >= 0 },
                       "the skipped list shows the binary, the 21 MB and the mixed-ending files")
                if let cell = p.table.view(atColumn: 0, row: row("huge.log"), makeIfNecessary: true) as? ResultCell {
                    let a = cell.label.attributedStringValue
                    let style = a.length > 0 ? a.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle : nil
                    expect(cell.label.maximumNumberOfLines == 1 && style?.lineBreakMode == .byTruncatingTail,
                           "a long skipped row stays on one line, cut at the end (it wrapped onto the next row)")
                }
                expect(!p.replaceAllButton.isHidden && p.replaceAllButton.isEnabled, "Replace All is offered")
                // Nothing written yet.
                expect(originals.allSatisfy { bytes($0.key) == $0.value }, "preview writes nothing")
                if let r = Optional(row("crlf.txt", line: 1)), r >= 0, let cell = p.table.view(atColumn: 0, row: r, makeIfNecessary: true) as? ResultCell {
                    let a = cell.label.attributedStringValue
                    expect(a.string == "1: owl one".replacingOccurrences(of: "owl", with: "owlhoot"), "a match row shows before → after", a.string)
                    var struck = false
                    a.enumerateAttribute(.strikethroughStyle, in: NSRange(location: 0, length: a.length)) { v, _, _ in if v != nil { struck = true } }
                    expect(struck, "…with the removed text struck through")
                }
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync { tab.window?.appearance = NSAppearance(named: .aqua); panel.table.reloadData(); panel.table.expandItem(nil, expandChildren: true) },
            snapshot("replaceinfiles-preview-light.png"),
            sync { tab.window?.appearance = NSAppearance(named: .darkAqua); panel.table.reloadData(); panel.table.expandItem(nil, expandChildren: true) },
            snapshot("replaceinfiles-preview-dark.png"),
            sync { tab.window?.appearance = nil },
            sync {
                // Uncheck a whole file, then one match of another, with clicks.
                let box = clickBox(row("unchecked.txt"))
                expect(box != nil, "unchecked.txt has a check box")
                expect(panel.nodes.first { $0.relativePath == "unchecked.txt" }?.children.allSatisfy { !$0.checked } == true,
                       "clicking a file's box unchecks its matches")
            },
            sync {
                _ = clickBox(row("partial.txt", line: 1).advanced(by: 1))
                let partial = panel.nodes.first { $0.relativePath == "partial.txt" }
                expect(partial?.children.map(\.checked) == [true, false], "clicking a match's box unchecks only that match",
                       "\(partial?.children.map(\.checked) ?? [])")
                expect(partial?.fileState == .mixed, "…and its file's box shows mixed")
                expect(panel.summary.stringValue.contains("6 replacements in 4 files") && panel.summary.stringValue.contains("2 unchecked"),
                       "the summary follows the boxes", panel.summary.stringValue)
            },
            sync {
                // Slowed down (0.3 s per file per stage, 3 files on disk: at least 2.7 s) to watch the app while it writes.
                ReplaceInFiles.writeDelayForChecks = 0.3
                replaceTickedWhileWriting = false
                click(panel.replaceAllButton, at: NSPoint(x: panel.replaceAllButton.bounds.midX, y: panel.replaceAllButton.bounds.midY))
                if !panel.replacing && panel.previewing {
                    print("check: note: synthetic click on Replace All not taken; pressing it")
                    panel.replaceAllButton.performClick(nil)
                }
                // Back from the click at once: the tab is edited here, the files are written in the background.
                expect(panel.replacing && ReplaceInFiles.writing, "Replace All returns while the files are written in the background")
                expect(tab.text == "hoot hoot disk\n", "the open tab's buffer is edited on the main thread first", tab.text.debugDescription)
                expect(["crlf.txt", "latin.txt", "partial.txt"].allSatisfy { bytes($0) == originals[$0] }, "…before any file on disk is written")
                expect(!panel.replaceAllButton.isEnabled && !panel.cancelPreviewButton.isEnabled && panel.undoButton.isHidden && !panel.replaceBox.isEnabled,
                       "while writing: Replace All, Cancel, Undo Replace and the Replace box are off")
                expect(menuItem(action: #selector(AppDelegate.undoReplaceInFilesMenu(_:))).map { !app.validateMenuItem($0) } == true,
                       "while writing: Edit › Undo Replace in Files is disabled")
                // A main-queue block queued now must run before the writes end:
                // the main thread is not blocked by them.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { if ReplaceInFiles.writing { replaceTickedWhileWriting = true } }
                }
            },
            // Not a fixed wait: a busy machine (the VM) can fire a timer late,
            // after the writes are done. Wait for the state itself.
            until("progress shows while the files are written", timeout: 5) {
                ReplaceInFiles.writing && panel.writeProgress.doubleValue > 0 && replaceTickedWhileWriting
            },
            sync {
                expect(replaceTickedWhileWriting && ReplaceInFiles.writing,
                       "the main thread runs while the files are written", panel.status.stringValue)
                let st = panel.status.stringValue
                expect(!panel.writeProgress.isHidden && panel.writeProgress.doubleValue > 0 && st.contains(" of 3 files"),
                       "progress is shown", "\(st) \(panel.writeProgress.doubleValue)")
                // Unchecking now changes nothing: the plan is taken.
                _ = clickBox(row("latin.txt"))
                expect(panel.nodes.first { $0.relativePath == "latin.txt" }?.children.allSatisfy(\.checked) == true, "boxes are locked while writing")
            },
            snapshot("replaceinfiles-writing.png"),
        ]
        steps += steps2
        let steps3: [Step] = [
            until("the writes land", timeout: 10) { !ReplaceInFiles.writing && !panel.replacing },
            sync {
                ReplaceInFiles.writeDelayForChecks = 0
                expect(ReplaceInFiles.lastWriteOnMain == false, "the files were read, backed up and written off the main thread")
                expect(panel.writeProgress.isHidden, "the progress bar goes when done")
                expect(!panel.previewing, "Replace All ends the preview", panel.summary.stringValue)
                print("check: after replace: \(panel.summary.stringValue)")
                expect(bytes("crlf.txt") == Data("hoot one\r\nhoot two\r\n".utf8), "CRLF file: replaced, CRLF kept",
                       String(decoding: bytes("crlf.txt") ?? Data(), as: UTF8.self).debugDescription)
                expect(mode("crlf.txt") == 0o640, "…and its mode 0640 kept", String(mode("crlf.txt"), radix: 8))
                expect(bytes("latin.txt") == "café hoot\n".data(using: .isoLatin1), "Latin-1 file: replaced, still Latin-1")
                expect(bytes("partial.txt") == Data("hoot A owl B\n".utf8), "the unchecked match is left", String(decoding: bytes("partial.txt") ?? Data(), as: UTF8.self))
                expect(bytes("unchecked.txt") == originals["unchecked.txt"], "the unchecked file is untouched")
                expect(bytes("mixed.txt") == originals["mixed.txt"], "the mixed-ending file is untouched")
                expect((try? Data(contentsOf: ignored)) == Data("owl ignored\n".utf8), "the git-ignored file is untouched")
                expect(bytes("open.txt") == originals["open.txt"], "the open tab's file on disk is untouched")
                expect(tab.text == "hoot hoot disk\n" && tab.doc.isDirty, "the open tab's buffer is replaced, unsaved", tab.text.debugDescription)
                expect(tab.textView.undoManager?.undoActionName == ReplaceInFiles.actionName, "…as one undo step named Replace in Files")
                expect(!panel.undoButton.isHidden, "Undo Replace is offered in the panel")
                let undoDirs = (try? FileManager.default.contentsOfDirectory(at: ReplaceInFiles.store.root, includingPropertiesForKeys: nil)) ?? []
                var st = stat()
                let priv = undoDirs.count == 1 && stat(undoDirs[0].path, &st) == 0 && st.st_mode & 0o777 == 0o700
                expect(priv, "originals backed up in one owner-only folder", "\(undoDirs)")
            },
            until("the results are searched again after the replace", timeout: 10) { panel.running == nil && panel.lastSummary != nil },
            sync {
                let files = Set(panel.results.map(\.relativePath))
                expect(!files.contains("crlf.txt") && !files.contains("latin.txt") && files.contains("unchecked.txt") && files.contains("partial.txt"),
                       "after Replace All the list shows the files as they are now (replaced matches gone)", "\(files.sorted())")
                expect(panel.nodes.allSatisfy { $0.children.allSatisfy { $0.result.map { $0.text.contains("owl") } ?? true } },
                       "…no stale rows")
                expect(panel.summary.stringValue.contains("Replaced") || panel.summary.stringValue.contains("replace"), "…the replace's report stays",
                       panel.summary.stringValue)
            },
            snapshot("replaceinfiles-replaced.png"),
            sync {
                let item = menuItem(action: #selector(AppDelegate.undoReplaceInFilesMenu(_:)))
                expect(item.map { app.validateMenuItem($0) } == true, "Edit › Undo Replace in Files is enabled")
                ReplaceInFiles.lastUndoOnMain = nil
                expect(choose(#selector(AppDelegate.undoReplaceInFilesMenu(_:))), "Edit › Undo Replace in Files runs")
            },
            until("the undo lands", timeout: 10) { !ReplaceInFiles.writing && !panel.replacing && ReplaceInFiles.lastUndoOnMain != nil },
            sync {
                let item = menuItem(action: #selector(AppDelegate.undoReplaceInFilesMenu(_:)))
                expect(ReplaceInFiles.lastUndoOnMain == false, "undo: the files were hashed and restored off the main thread")
                for k in ["crlf.txt", "latin.txt", "partial.txt", "unchecked.txt", "mixed.txt", "open.txt"] {
                    expect(bytes(k) == originals[k], "undo: \(k) is byte-for-byte the original")
                }
                expect(mode("crlf.txt") == 0o640, "undo: mode still 0640")
                expect(tab.text == "owl owl disk\n", "undo: the tab is back to its unsaved text", tab.text.debugDescription)
                expect(item.map { app.validateMenuItem($0) } == false, "Undo Replace in Files is disabled again")
                expect(panel.summary.stringValue.contains("in 4 files"), "the panel reports the undo", panel.summary.stringValue)
            },
            until("the results are searched again after the undo", timeout: 10) { panel.running == nil && panel.lastSummary != nil },
            sync {
                let files = Set(panel.results.map(\.relativePath))
                expect(files.isSuperset(of: ["crlf.txt", "latin.txt", "partial.txt", "unchecked.txt"]), "after the undo the list shows the matches again",
                       "\(files.sorted())")
                expect(panel.summary.stringValue.contains("in 4 files"), "…and the undo's report stays", panel.summary.stringValue)
            },
        ]
        steps += steps3
        let steps4: [Step] = [
            sync {
                // Find users see the panel as before: no Replace row once Replace is off.
                click(panel.replaceBox, at: NSPoint(x: 4, y: panel.replaceBox.bounds.midY))
                if panel.replaceMode {
                    print("check: note: synthetic click not taken by the Replace box; pressing it")
                    panel.replaceBox.performClick(nil)
                }
                expect(!panel.replaceMode && panel.replaceField.superview?.isHidden == true, "turning Replace off hides the Replace row")
            },
            // 0.2.1: Edit › Undo Replace in Files with the panel hidden shows
            // its progress and its result in the tab.
            sync {
                app.hideFindInFiles()
                expect(app.findInFiles?.isShown != true, "panel hidden")
                let files = ["partial.txt", "unchecked.txt"].compactMap { url[$0] }
                let cands = files.map { FileReplace.Candidate(url: $0, relativePath: $0.lastPathComponent, searchStamp: DiskStamp.of($0)) }
                guard let plan = try? FileReplace.plan(ReplaceQuery(query: "owl", template: "OWL"), root: root, candidates: cands) else {
                    expect(false, "hidden panel: plan"); return
                }
                app.applyReplace(plan) { _ in }
            },
            until("hidden panel: the replace lands", timeout: 10) { !ReplaceInFiles.writing && ReplaceInFiles.last != nil },
            sync {
                expect(bytes("partial.txt") == Data("OWL A OWL B\n".utf8), "hidden panel: replaced on disk")
                ReplaceInFiles.writeDelayForChecks = 0.4
                expect(choose(#selector(AppDelegate.undoReplaceInFilesMenu(_:))), "hidden panel: Edit › Undo Replace in Files runs")
                expect(tab.noticeBar?.isHidden == false && tab.noticeBar?.label.stringValue.hasPrefix("Undoing Replace in Files…") == true,
                       "hidden panel: the tab says the undo is under way", tab.noticeBar?.label.stringValue ?? "-")
            },
            until("hidden panel: progress per file", timeout: 5) { tab.noticeBar?.label.stringValue.contains(" of 2 files") == true },
            snapshot("replaceinfiles-undo-hidden-progress.png"),
            until("hidden panel: the undo lands", timeout: 10) { !ReplaceInFiles.writing },
            sync {
                ReplaceInFiles.writeDelayForChecks = 0
                let text = tab.noticeBar?.label.stringValue ?? "-"
                expect(tab.noticeBar?.isHidden == false && text.hasPrefix("Undid Replace in Files in 2 files"), "hidden panel: then the result", text)
                expect(bytes("partial.txt") == originals["partial.txt"] && bytes("unchecked.txt") == originals["unchecked.txt"],
                       "hidden panel: the files are back")
                expect(tab.noticeBar?.button("Dismiss") != nil, "hidden panel: with Dismiss")
                tab.noticeBar?.button("Dismiss")?.performClick(nil)
                expect(tab.noticeBar?.isHidden == true, "hidden panel: Dismiss closes it")
            },
        ]
        steps += steps4
        steps += replaceAliasSteps(app, root: root)
        steps += replaceExactTextSteps(app, root: root)
        steps += replaceStaleTabSteps(app, root: root)
        run(steps)
    }

    /// Astra batch 17v must 4: a tab opened under another spelling of the
    /// same file (case, NFD for an NFC name, the Data volume's firmlinked
    /// path to the folder, a hard link: one file by device and inode) is
    /// that file's tab. Path resolution turns the first three into the
    /// listed spelling on APFS; only identity finds the hard link. Planning takes its unsaved text, and Replace All edits
    /// the tab's buffer and never writes the file, both when the plan came
    /// from the tab and when it came from disk while the tab was open.
    static func replaceAliasSteps(_ app: AppDelegate, root: URL) -> [Step] {
        let caseDisk = root.appendingPathComponent("alias-case.txt"), caseTab = root.appendingPathComponent("ALIAS-CASE.TXT")
        let nfcDisk = root.appendingPathComponent("caf\u{E9}-alias.txt"), nfdTab = root.appendingPathComponent("cafe\u{301}-alias.txt")
        // The Data volume's firmlinked path to the same folder: realpath keeps it, so only identity says it is the same file.
        let firm = URL(fileURLWithPath: "/System/Volumes/Data" + (CLIHandoff.realpath(root.path) ?? root.path))
        let firmDisk = root.appendingPathComponent("alias-firm.txt"), firmTab = firm.appendingPathComponent("alias-firm.txt")
        // A hard link: the same file by another path, which no path resolution turns into the listed one.
        let linkDisk = root.appendingPathComponent("alias-link.txt"), linkTab = root.appendingPathComponent("alias-link-2.txt")
        let applyDisk = root.appendingPathComponent("alias-apply.txt"), applyTab = firm.appendingPathComponent("Alias-Apply.TXT")
        let dirtyDisk = root.appendingPathComponent("alias-dirty.txt"), dirtyTab = firm.appendingPathComponent("ALIAS-dirty.txt")
        let onlyDisk = root.appendingPathComponent("alias-only.txt"), onlyTab = root.appendingPathComponent("alias-only-2.txt")
        let disk = Data("owl alias\n".utf8)
        func read(_ u: URL) -> Data? { try? Data(contentsOf: u) }
        var tabs: [EditorWindowController] = []
        let q = ReplaceQuery(query: "owl", template: "hoot")
        return [
            sync {
                // Made only now, after the main check's previews (they'd show up there).
                for u in [caseDisk, nfcDisk, firmDisk, linkDisk, applyDisk, dirtyDisk, onlyDisk] { try? disk.write(to: u) }
                for (a, b) in [(linkDisk, linkTab), (onlyDisk, onlyTab)] { link(a.path, b.path) }
                let same = [(caseDisk, caseTab), (nfcDisk, nfdTab), (firmDisk, firmTab), (linkDisk, linkTab), (applyDisk, applyTab), (dirtyDisk, dirtyTab), (onlyDisk, onlyTab)].allSatisfy {
                    Beneath.FileID(path: $0.0.path, followLast: true) == Beneath.FileID(path: $0.1.path, followLast: true)
                }
                expect(same, "alias: each tab spelling is the same file as the listed one (APFS)",
                       [(caseDisk, caseTab), (nfcDisk, nfdTab), (firmDisk, firmTab), (linkDisk, linkTab), (applyDisk, applyTab), (dirtyDisk, dirtyTab)].map {
                           "\($0.1.path)=\(Beneath.FileID(path: $0.0.path, followLast: true) == Beneath.FileID(path: $0.1.path, followLast: true))"
                       }.joined(separator: " "))
                guard same else { tabs = []; return }
                tabs = [caseTab, nfdTab, firmTab, linkTab, applyTab, dirtyTab, onlyTab].compactMap { app.open($0) }
                expect(tabs.count == 7, "alias: seven tabs opened under the other spellings")
                expect(zip(tabs, [caseTab, nfdTab, firmTab, linkTab, applyTab, dirtyTab]).allSatisfy { FolderTree.sameBytes($0.0.doc.fileURL?.path ?? "", $0.1.path) },
                       "alias: …and they keep that spelling", tabs.map { $0.doc.fileURL?.path ?? "-" }.joined(separator: ", "))
            },
            until("alias: the tabs are read", timeout: 10) { tabs.count == 7 && tabs.allSatisfy { $0.text == "owl alias\n" } },
            sync {
                // Unsaved text in the first four; the last two hold the disk's text (planned from disk below).
                for t in tabs.prefix(4) { t.textView.insertText("owl unsaved ", replacementRange: NSRange(location: 0, length: 0)) }
                expect(tabs.prefix(4).allSatisfy { $0.doc.isDirty && $0.text == "owl unsaved owl alias\n" }, "alias: four tabs hold unsaved text")
                // Planning, from the listed spelling: the tab's text, not the disk's.
                let listed = [caseDisk, nfcDisk, firmDisk, linkDisk]
                let cands = listed.map { FileReplace.Candidate(url: $0, relativePath: $0.lastPathComponent, searchStamp: DiskStamp.of($0)) }
                guard let plan = try? FileReplace.plan(q, root: root, candidates: cands, buffers: app.openBuffers(for: listed)) else {
                    expect(false, "alias: plan"); return
                }
                expect(plan.files.count == 4 && plan.files.allSatisfy { $0.disk == nil && $0.sourceText == "owl unsaved owl alias\n" && $0.edits.count == 2 },
                       "alias: planning takes each alias tab's unsaved text (case, NFD, firmlinked path, hard link)",
                       plan.files.map { "\($0.relativePath) disk=\($0.disk != nil) \($0.sourceText.debugDescription)" }.joined(separator: "; "))
                app.applyReplace(plan) { _ in }
            },
            until("alias: the tab-planned replace lands", timeout: 10) { !ReplaceInFiles.writing },
            sync {
                expect(tabs.prefix(4).allSatisfy { $0.text == "hoot unsaved hoot alias\n" && $0.doc.isDirty },
                       "alias: Replace All edits the alias tabs' buffers", tabs.prefix(4).map(\.text.debugDescription).joined(separator: ", "))
                expect([caseDisk, nfcDisk, firmDisk, linkDisk].allSatisfy { read($0) == disk }, "alias: …and writes none of their files on disk")
                // Planned from disk (no buffers) while the last two are open under the firmlinked path,
                // the sixth with unsaved text typed after the plan.
                let cs = [applyDisk, dirtyDisk].map { FileReplace.Candidate(url: $0, relativePath: $0.lastPathComponent, searchStamp: DiskStamp.of($0)) }
                guard let plan = try? FileReplace.plan(q, root: root, candidates: cs), plan.files.count == 2, plan.files.allSatisfy({ $0.disk != nil }) else {
                    expect(false, "alias: disk plan"); return
                }
                tabs[5].textView.insertText("typed ", replacementRange: NSRange(location: 0, length: 0))
                app.applyReplace(plan) { _ in }
            },
            until("alias: the disk-planned replace lands", timeout: 10) { !ReplaceInFiles.writing },
            sync {
                expect(tabs[4].text == "hoot alias\n", "alias: apply finds the open alias tab and edits its buffer", tabs[4].text.debugDescription)
                expect(read(applyDisk) == disk, "alias: …never the file behind it",
                       String(decoding: read(applyDisk) ?? Data(), as: UTF8.self).debugDescription)
                expect(tabs[5].text == "typed owl alias\n" && tabs[5].doc.isDirty && read(dirtyDisk) == disk,
                       "alias: a dirty alias tab changed since the plan is skipped: its buffer kept, its file not written",
                       "\(tabs[5].text.debugDescription) disk=\(String(decoding: read(dirtyDisk) ?? Data(), as: UTF8.self).debugDescription)")
                // Apply on its own: a plan from the tab's text for the listed path, the tab open as a hard link.
                tabs[6].textView.insertText("owl unsaved ", replacementRange: NSRange(location: 0, length: 0))
                let c = FileReplace.Candidate(url: onlyDisk, relativePath: onlyDisk.lastPathComponent, searchStamp: DiskStamp.of(onlyDisk))
                guard let plan = try? FileReplace.plan(q, root: root, candidates: [c], buffers: [onlyDisk.standardizedFileURL.path: OpenBuffer(text: tabs[6].text, fileID: tabs[6].doc.diskStamp.identity)]),
                      plan.files.first?.disk == nil else { expect(false, "alias: tab plan for apply"); return }
                app.applyReplace(plan) { _ in }
            },
            until("alias: the apply-only replace lands", timeout: 10) { !ReplaceInFiles.writing },
            sync {
                expect(tabs[6].text == "hoot unsaved hoot alias\n" && read(onlyDisk) == disk,
                       "alias: apply edits the tab open as another path to the file (a hard link), not the disk",
                       "\(tabs[6].text.debugDescription) disk=\(String(decoding: read(onlyDisk) ?? Data(), as: UTF8.self).debugDescription)")
            },
        ]
    }

    /// Sol 21v-3 (class i): the preview replaces "b" in the tab's
    /// "\u{E9}ab", then the tab's text becomes the canonically equal
    /// "e\u{301}ab" before Replace All. Swift's == says nothing changed,
    /// but the planned UTF-16 range would now cover "a": the tab is
    /// skipped as changed since the preview, its text and its file kept.
    static func replaceExactTextSteps(_ app: AppDelegate, root: URL) -> [Step] {
        let file = root.appendingPathComponent("exact-text.txt")
        let disk = Data("\u{E9}ab\n".utf8)
        let changed = "e\u{301}ab\n"
        var tab: EditorWindowController?
        var message = ""
        func exact(_ a: String, _ b: String) -> Bool { Array(a.utf16) == Array(b.utf16) }
        return [
            sync {
                try? disk.write(to: file)
                tab = app.open(file)
                expect(tab != nil, "exact text: the tab opens")
            },
            until("exact text: the tab is read", timeout: 10) { tab.map { exact($0.text, "\u{E9}ab\n") } == true },
            sync {
                guard let tab else { return }
                let q = ReplaceQuery(query: "b", template: "X", caseSensitive: true)
                let c = FileReplace.Candidate(url: file, relativePath: file.lastPathComponent, searchStamp: DiskStamp.of(file))
                guard let plan = try? FileReplace.plan(q, root: root, candidates: [c], buffers: app.openBuffers(for: [file])),
                      plan.files.count == 1, plan.files[0].disk == nil, plan.files[0].edits.map(\.range) == [NSRange(location: 2, length: 1)] else {
                    expect(false, "exact text: planned from the tab, \"b\" at UTF-16 offset 2"); return
                }
                // The same text to Swift, one UTF-16 unit longer.
                tab.textView.insertText("e\u{301}", replacementRange: NSRange(location: 0, length: 1))
                expect(exact(tab.text, changed) && tab.text == plan.files[0].sourceText,
                       "exact text: the tab now holds NFD text Swift calls equal to the planned text", Array(tab.text.utf16).description)
                app.applyReplace(plan) { message = $0 }
            },
            until("exact text: the replace lands", timeout: 10) { !ReplaceInFiles.writing && !message.isEmpty },
            sync {
                guard let tab else { return }
                expect(exact(tab.text, changed), "exact text: Replace All leaves the changed tab alone (no edit at the stale offset)",
                       Array(tab.text.utf16).description)
                expect(message.contains("exact-text.txt (\(ReplaceSkip.changedSincePreview.summary))"),
                       "exact text: …and says it changed since the preview", message)
                expect((try? Data(contentsOf: file)) == disk, "exact text: …and its file is not written")
            },
        ]
    }

    /// Sol 21v-3 (class i): a tab with unsaved text, previewed from its
    /// buffer; then a sync client (or a restore) puts another file at the
    /// same spelling (written beside it, renamed over it: a new inode)
    /// before Replace All. The tab holds the old file's text, so it isn't
    /// that file's tab any more: Replace All skips it (out of date), its
    /// text kept and the new file not written; a new preview with the
    /// stale tab still open plans neither the tab nor the disk. Same for
    /// a file deleted between the preview and Replace All.
    static func replaceStaleTabSteps(_ app: AppDelegate, root: URL) -> [Step] {
        let staleFile = root.appendingPathComponent("stale-tab.txt"), goneFile = root.appendingPathComponent("gone-tab.txt")
        let disk = Data("owl stale\n".utf8), synced = Data("owl synced\n".utf8)
        let typed = "owl unsaved owl stale\n"
        var stale: EditorWindowController?, gone: EditorWindowController?
        var message = ""
        let q = ReplaceQuery(query: "owl", template: "hoot")
        let outOfDate = ReplaceSkip.tabOutOfDate.summary
        func read(_ u: URL) -> Data? { try? Data(contentsOf: u) }
        func cands(_ u: URL) -> [FileReplace.Candidate] { [.init(url: u, relativePath: u.lastPathComponent, searchStamp: DiskStamp.of(u))] }
        return [
            sync {
                for u in [staleFile, goneFile] { try? disk.write(to: u) }
                stale = app.open(staleFile)
                gone = app.open(goneFile)
                expect(stale != nil && gone != nil, "stale tab: the tabs open")
            },
            until("stale tab: the tabs are read", timeout: 10) { stale?.text == "owl stale\n" && gone?.text == "owl stale\n" },
            sync {
                guard let stale, let gone else { return }
                for t in [stale, gone] { t.textView.insertText("owl unsaved ", replacementRange: NSRange(location: 0, length: 0)) }
                guard let plan = try? FileReplace.plan(q, root: root, candidates: cands(staleFile) + cands(goneFile),
                                                       buffers: app.openBuffers(for: [staleFile, goneFile])),
                      plan.files.count == 2, plan.files.allSatisfy({ $0.disk == nil && $0.sourceText == typed }) else {
                    expect(false, "stale tab: planned from both tabs' unsaved text"); return
                }
                // The sync client: another file at the same spelling. And the other file deleted.
                let before = DiskStamp.of(staleFile)?.identity
                let tmp = root.appendingPathComponent(".stale-tab.sync")
                try? synced.write(to: tmp)
                rename(tmp.path, staleFile.path)
                unlink(goneFile.path)
                expect(before != nil && DiskStamp.of(staleFile)?.identity != before && read(staleFile) == synced && read(goneFile) == nil,
                       "stale tab: the file at the tab's path is another file now, the other one gone")
                expect(stale.text == typed && stale.doc.isDirty && FolderTree.sameBytes(stale.doc.fileURL?.path ?? "", staleFile.path),
                       "stale tab: …while the tab, at that same path, holds the old file's text")
                app.applyReplace(plan) { message = $0 }
            },
            until("stale tab: the replace lands", timeout: 10) { !ReplaceInFiles.writing && !message.isEmpty },
            sync {
                guard let stale, let gone else { return }
                expect(stale.text == typed && gone.text == typed, "stale tab: Replace All edits neither tab",
                       "\(stale.text.debugDescription) \(gone.text.debugDescription)")
                expect(message.contains("stale-tab.txt (\(outOfDate))") && message.contains("gone-tab.txt (\(outOfDate))"),
                       "stale tab: …and says each is out of date with its file", message)
                expect(read(staleFile) == synced && read(goneFile) == nil, "stale tab: …and writes no file",
                       String(decoding: read(staleFile) ?? Data(), as: UTF8.self).debugDescription)
                // A new preview with the stale tab open: no plan from the tab or from the disk behind it.
                guard let again = try? FileReplace.plan(q, root: root, candidates: cands(staleFile), buffers: app.openBuffers(for: [staleFile])) else {
                    expect(false, "stale tab: second plan"); return
                }
                expect(again.files.isEmpty && again.skipped.map(\.reason) == [.tabOutOfDate],
                       "stale tab: a new preview plans neither the stale tab nor the file behind it",
                       "files=\(again.files.count) skipped=\(again.skipped.map(\.reason.rawValue))")
            },
        ]
    }

    /// A Phase 0 menu item: it exists, has its shortcut (if any) and
    /// validates to disabled until its feature lands (still used by the
    /// other 0.2.0 stub checks until they are replaced).
    static func expectScaffold(_ app: AppDelegate, _ action: Selector, _ name: String,
                               _ key: String = "", _ mods: NSEvent.ModifierFlags = []) {
        guard let i = menuItem(action: action) else { expect(false, "\(name) is in the menu"); return }
        let ok = i.keyEquivalent == key && (key.isEmpty || i.keyEquivalentModifierMask == mods)
        expect(ok, "\(name) is in the menu" + (key.isEmpty ? "" : " as \(MenuShortcuts.name(i))"),
               "\(MenuShortcuts.name(i)) \(i.keyEquivalent.unicodeScalars.map { $0.value })")
        expect(!app.validateMenuItem(i), "\(name) is disabled (scaffold)")
    }
}
