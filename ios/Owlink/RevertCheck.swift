#if DEBUG
import UIKit
import CedricCore

/// Debug builds only: `-OwlinkRevertCheck <dir>` runs Revert to Opened
/// Version and Restore Previous Version against a real document after
/// saves (what the save check doesn't cover), writes <dir>/revertcheck.txt
/// (PASS/FAIL/INFO lines) and quits.
@MainActor
enum RevertCheck {
    static var outDir: URL? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-OwlinkRevertCheck"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1])
    }

    private static var log: [String] = [] { didSet { flush() } }
    private static var out: URL?

    /// Written after every line, so a step that hangs shows where.
    private static func flush() {
        guard let out else { return }
        try? log.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("revertcheck.log"), atomically: true, encoding: .utf8)
    }
    private static var failures = 0

    static func check(_ ok: Bool, _ what: String) {
        log.append((ok ? "PASS " : "FAIL ") + what)
        if !ok { failures += 1 }
    }

    static func info(_ s: String) { log.append("INFO " + s) }

    static func run(in window: UIWindow, browser: UIViewController, out: URL) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            Self.out = out
            info("started")
            let saveSetting = AppSettings.saveAutomatically
            await steps(window, browser, out)
            AppSettings.saveAutomatically = saveSetting
            log.append(failures == 0 ? "revertcheck: all passed" : "revertcheck: \(failures) failed")
            try? log.joined(separator: "\n").appending("\n").write(to: out.appendingPathComponent("revertcheck.txt"), atomically: true, encoding: .utf8)
            exit(failures == 0 ? 0 : 1)
        }
    }

    static func wait(_ seconds: Double, until: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 10) {
            if until() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return until()
    }

    static func disk(_ url: URL) -> String { (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>" }

    static func save(_ doc: TextDocument) async -> Bool {
        await withCheckedContinuation { c in doc.save(to: doc.fileURL, for: .forOverwriting) { c.resume(returning: $0) } }
    }

    static func present(_ editor: EditorViewController, over browser: UIViewController) async {
        let nav = UINavigationController(rootViewController: editor)
        nav.modalPresentationStyle = .fullScreen
        for _ in 0..<60 where browser.presentedViewController == nil {
            if browser.view.window != nil { browser.present(nav, animated: false) }
            try? await Task.sleep(for: .milliseconds(500))
        }
        _ = await wait(15) { editor.view.window != nil && !editor.textView.text.isEmpty }
        try? await Task.sleep(for: .milliseconds(500))
    }

    static func dismiss(_ browser: UIViewController) async {
        if browser.presentedViewController != nil {
            await withCheckedContinuation { c in browser.dismiss(animated: false) { c.resume() } }
        }
    }

    static func close(_ doc: TextDocument) async {
        _ = await withCheckedContinuation { c in doc.close { c.resume(returning: $0) } }
        doc.discardOpenedCopy()
    }

    private static func steps(_ window: UIWindow, _ browser: UIViewController, _ out: URL) async {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("revertcheck.txt")
        try? FileManager.default.removeItem(at: url)
        let original = "line one\nline two\n"
        try? original.write(to: url, atomically: true, encoding: .utf8)
        // Copies from an earlier run of this check go.
        SaveSafetyStores.flush()
        for c in SaveSafetyStores.copies.copies(forDocumentPath: url.standardizedFileURL.path) { SaveSafetyStores.copies.remove(c) }
        AppSettings.saveAutomatically = false

        // 1. Open, edit, save, edit, save; Revert to Opened Version.
        let doc = TextDocument(fileURL: url)
        let opened = await withCheckedContinuation { c in doc.open { c.resume(returning: $0) } }
        check(opened, "opened the file")
        guard opened else { return }
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        await present(editor, over: browser)
        let tv = editor.textView
        check(tv.text == original, "editor shows the file")
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        tv.insertText("edit A\n")
        check(await save(doc), "first save")
        check(disk(url) == original + "edit A\n", "disk has edit A")
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        tv.insertText("edit B\n")
        check(await save(doc), "second save")
        check(disk(url) == original + "edit A\nedit B\n", "disk has edits A and B")
        SaveSafetyStores.flush()
        let copies = SaveSafetyStores.copies.copies(forDocumentPath: doc.recoveryPath)
        info("safety copies after two saves: \(copies.map { "\($0.kind.rawValue) \($0.byteCount)b" })")
        check(copies.count >= 1, "Restore Previous Version has at least one copy after saving")

        editor.revertToOpened()
        try? await Task.sleep(for: .milliseconds(300))
        check(tv.text == original, "after two saves, Revert to Opened shows the text as opened")
        check(doc.hasUnsavedChanges && editor.editedShown, "the reverted text is Edited (it differs from the file)")
        check(await save(doc), "save after revert")
        check(disk(url) == original, "the file is back to the opened version after saving")
        check(!doc.hasUnsavedChanges && !editor.editedShown, "Edited clears after saving the revert")
        tv.undoManager?.undo()
        check(tv.text == original + "edit A\nedit B\n", "Undo after Revert brings back the saved edits")
        tv.undoManager?.redo()
        check(tv.text == original, "Redo reverts again")
        check(!doc.hasUnsavedChanges && !editor.editedShown, "Redo back to the saved text is not Edited")
        info("after redo: unsaved \(doc.hasUnsavedChanges) edited \(editor.editedShown)")

        // 2. Unsaved edits only: Revert gives back exactly the file.
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        tv.insertText("unsaved C\n")
        check(doc.hasUnsavedChanges, "typing marks Edited")
        editor.revertToOpened()
        try? await Task.sleep(for: .milliseconds(300))
        check(tv.text == original, "Revert with unsaved edits shows the opened text")
        info("revert to text equal to disk: unsaved \(doc.hasUnsavedChanges) edited \(editor.editedShown)")
        check(!doc.hasUnsavedChanges && !editor.editedShown, "reverting to what is on disk is not Edited")

        // 2a. Undo while a save is writing the edited text.
        tv.undoManager?.removeAllActions()
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        tv.insertText("inflight X\n")
        try? await Task.sleep(for: .milliseconds(100))
        var editedRightAfterUndo = false
        let inflightSaved = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            doc.save(to: doc.fileURL, for: .forOverwriting) { c.resume(returning: $0) }
            tv.undoManager?.undo()
            editedRightAfterUndo = doc.hasUnsavedChanges
        }
        check(editedRightAfterUndo, "undo while the save is still writing doesn't mark the text saved")
        check(inflightSaved, "in-flight save succeeded")
        check(disk(url).contains("inflight X"), "the in-flight save wrote the edited text")
        check(doc.hasUnsavedChanges, "undo during a save in flight stays Edited (the file has the undone text)")
        check(await save(doc), "save after undo during a save")
        check(!disk(url).contains("inflight X"), "saving the undo removes the in-flight text")
        check(!doc.hasUnsavedChanges && !editor.editedShown, "Edited clears after saving the undo")

        // 2b. Canonically equal characters still have different bytes.
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        let characterOffset = tv.selectedRange.location
        tv.insertText("\u{00C5}\n")
        check(await save(doc), "save the first canonical character")
        if let start = tv.position(from: tv.beginningOfDocument, offset: characterOffset),
           let end = tv.position(from: start, offset: 1),
           let range = tv.textRange(from: start, to: end) {
            tv.replace(range, withText: "\u{212B}")
            editor.textViewDidChange(tv)
            check(doc.hasUnsavedChanges, "a canonically equal but different character is Edited")
            check(await save(doc), "save the different canonical character")
            let bytes = (try? Data(contentsOf: url)) ?? Data()
            check(bytes.range(of: Data([0xE2, 0x84, 0xAB])) != nil, "disk has the UTF-8 bytes of the replacement")
        } else {
            check(false, "the canonical character range exists")
        }

        // 2c. Keep Mine must overwrite theirs even after an edit is undone.
        doc.keepMineAfterExternalChange()
        tv.undoManager?.removeAllActions()
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        tv.insertText("k\n")
        try? await Task.sleep(for: .milliseconds(100))
        tv.undoManager?.undo()
        check(doc.hasUnsavedChanges, "after Keep Mine, undoing back to the old text stays Edited")
        check(await save(doc), "save after Keep Mine")
        check(!doc.hasUnsavedChanges && !editor.editedShown && !doc.diskStateStale, "saving after Keep Mine clears Edited")

        // 3. Restore Previous Version: the copy before Owlink first saved.
        tv.selectedRange = NSRange(location: (tv.text as NSString).length, length: 0)
        tv.insertText("edit D\n")
        check(await save(doc), "save edit D")
        SaveSafetyStores.flush()
        let copies2 = SaveSafetyStores.copies.copies(forDocumentPath: doc.recoveryPath)
        info("safety copies now: \(copies2.map { "\($0.kind.rawValue) \($0.byteCount)b \(String(data: SaveSafetyStores.copies.data(for: $0) ?? Data(), encoding: .utf8)?.debugDescription ?? "")" })")
        let pinned = copies2.first { $0.kind == .original && $0.pinned == true }
        check(pinned.flatMap { SaveSafetyStores.copies.data(for: $0) } == Data(original.utf8),
              "the pinned copy contains the original text")
        if let c = copies2.first(where: { $0.kind == .original && SaveSafetyStores.copies.data(for: $0) == Data(original.utf8) }) {
            editor.restore(c)
            try? await Task.sleep(for: .milliseconds(300))
            check(tv.text == original, "Restore Previous Version (Before Owlink saved) shows the original text")
            check(doc.hasUnsavedChanges, "the restored text is Edited")
        } else {
            check(false, "a Before Owlink saved copy exists")
        }
        await dismiss(browser)
        await close(doc)

        // 4. Open again (a new session): Revert to Opened is this open's text,
        // and earlier versions are still offered.
        let before2 = disk(url)
        let doc2 = TextDocument(fileURL: url)
        let opened2 = await withCheckedContinuation { c in doc2.open { c.resume(returning: $0) } }
        check(opened2, "opened again")
        let editor2 = EditorViewController(document: doc2, readModeOnOpen: true)
        await present(editor2, over: browser)
        let tv2 = editor2.textView
        SaveSafetyStores.flush()
        let copies3 = SaveSafetyStores.copies.copies(forDocumentPath: doc2.recoveryPath)
        info("reopen: copies \(copies3.count), opened copy \(String(describing: doc2.openedCopy))")
        check(!copies3.isEmpty, "earlier versions still offered after reopening")
        // From read mode: Revert is an explicit change, allowed without Edit.
        editor2.startEditing()
        tv2.selectedRange = NSRange(location: (tv2.text as NSString).length, length: 0)
        tv2.insertText("session 2\n")
        check(await save(doc2), "save in session 2")
        editor2.stopEditing()
        editor2.revertToOpened()
        try? await Task.sleep(for: .milliseconds(300))
        check(tv2.text == before2, "from read mode, Revert to Opened shows this session's opened text")
        check(await save(doc2), "save after revert in session 2")
        check(disk(url) == before2, "the file is back to this session's opened version")

        // 5. The file was reloaded from disk (as Use Theirs does after a
        // change elsewhere): Revert to Opened still means the text as first
        // opened, not the reloaded one.
        let external = before2 + "from elsewhere\n"
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                var err: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: url, options: [], error: &err) { u in
                    try? external.write(to: u, atomically: true, encoding: .utf8)
                }
                c.resume()
            }
        }
        if tv2.text != external {
            _ = await withCheckedContinuation { c in doc2.revertAfterChoice { c.resume(returning: $0) } }
        }
        let reloaded = await wait(10) { tv2.text == external }
        check(reloaded, "the reload shows the file's new text")
        editor2.revertToOpened()
        try? await Task.sleep(for: .milliseconds(300))
        check(tv2.text == before2, "after a reload, Revert to Opened still shows the text as opened")
        await dismiss(browser)
        await close(doc2)

        // 6. Each save preserves the preceding disk state, up to the cap.
        let historyURL = docs.appendingPathComponent("historycheck.txt")
        try? FileManager.default.removeItem(at: historyURL)
        try? "v0\n".write(to: historyURL, atomically: true, encoding: .utf8)
        let store = SaveSafetyStores.copies
        SaveSafetyStores.flush()
        for copy in store.copies(forDocumentPath: historyURL.standardizedFileURL.path) { store.remove(copy) }
        let historyDoc = TextDocument(fileURL: historyURL)
        let historyOpened = await withCheckedContinuation { c in historyDoc.open { c.resume(returning: $0) } }
        check(historyOpened, "opened the history check file")
        guard historyOpened else { return }
        let historyEditor = EditorViewController(document: historyDoc, readModeOnOpen: false)
        await present(historyEditor, over: browser)
        let historyText = historyEditor.textView
        func originals() -> [SafetyCopy] {
            SaveSafetyStores.flush()
            return store.copies(forDocumentPath: historyDoc.recoveryPath).filter { $0.kind == .original }
        }
        func copyText(_ copy: SafetyCopy) -> String? {
            store.data(for: copy).flatMap { String(data: $0, encoding: .utf8) }
        }
        func replaceHistoryText(_ text: String) {
            guard let range = historyText.textRange(from: historyText.beginningOfDocument, to: historyText.endOfDocument) else {
                check(false, "history text range exists")
                return
            }
            historyText.replace(range, withText: text)
            historyEditor.textViewDidChange(historyText)
        }
        for i in 1...3 {
            replaceHistoryText("v\(i)\n")
            check(await save(historyDoc), "history save v\(i)")
        }
        let historyCopies = originals()
        check(historyCopies.map { copyText($0) } == ["v2\n", "v1\n", "v0\n"],
              "previous versions are v2, v1, v0 newest first")
        if historyCopies.count >= 2 {
            historyEditor.restore(historyCopies[0])
            check(historyText.text == "v2\n" && historyDoc.hasUnsavedChanges && historyEditor.editedShown,
                  "restoring v2 is Edited")
            historyEditor.restore(historyCopies[1])
            check(historyText.text == "v1\n" && historyDoc.hasUnsavedChanges && historyEditor.editedShown,
                  "restoring v1 is Edited")
            check(await save(historyDoc), "save restored v1")
            check(disk(historyURL) == "v1\n" && !historyDoc.hasUnsavedChanges && !historyEditor.editedShown,
                  "saved v1 is on disk and not Edited")
            if let same = originals().first(where: { copyText($0) == "v1\n" }) {
                historyEditor.restore(same)
                check(historyText.text == "v1\n" && !historyDoc.hasUnsavedChanges && !historyEditor.editedShown,
                      "restoring the disk version is not Edited")
            }
            if let v3 = originals().first(where: { copyText($0) == "v3\n" }) {
                historyText.undoManager?.removeAllActions()
                historyEditor.restore(v3)
                check(historyText.text == "v3\n" && historyDoc.hasUnsavedChanges && historyEditor.editedShown,
                      "restoring v3 is Edited")
                historyText.undoManager?.undo()
                check(historyText.text == "v1\n" && !historyDoc.hasUnsavedChanges && !historyEditor.editedShown,
                      "undo after restore returns to saved v1, not Edited")
            } else {
                check(false, "v3 was kept before saving restored v1")
            }
        } else {
            check(false, "history has both versions to restore")
        }
        historyEditor.revertToOpened()
        check(historyText.text == "v0\n", "history Revert to Opened still shows v0")
        for i in 1...12 {
            replaceHistoryText("history \(i)\n")
            check(await save(historyDoc), "capped history save \(i)")
        }
        let capped = originals()
        check(capped.count == SafetyCopyStore.saveHistoryLimit + 1, "save history is capped at 10 plus the pinned version")
        check(capped.map { copyText($0) } == (2...11).reversed().map { "history \($0)\n" } + ["v0\n"],
              "history keeps the newest ten and pinned version, dropping other old copies")
        check(await save(historyDoc), "unchanged history save")
        check(originals().map(\.id) == capped.map(\.id), "unchanged save adds no history copy")
        await dismiss(browser)
        await close(historyDoc)

        // 7. Autosaves are thinned: within 60 s of the last copy an autosave
        // adds none; an explicit save still does.
        let thinURL = docs.appendingPathComponent("thincheck.txt")
        try? FileManager.default.removeItem(at: thinURL)
        try? "t0\n".write(to: thinURL, atomically: true, encoding: .utf8)
        for copy in store.copies(forDocumentPath: thinURL.standardizedFileURL.path) { store.remove(copy) }
        let thinDoc = TextDocument(fileURL: thinURL)
        let thinOpened = await withCheckedContinuation { c in thinDoc.open { c.resume(returning: $0) } }
        check(thinOpened, "opened the thinning check file")
        guard thinOpened else { return }
        AppSettings.saveAutomatically = true
        func thinOriginals() -> [SafetyCopy] {
            SaveSafetyStores.flush()
            return store.copies(forDocumentPath: thinDoc.recoveryPath).filter { $0.kind == .original }
        }
        func autosave(_ text: String) async -> Bool {
            thinDoc.text = text
            thinDoc.updateChangeCount(.done)
            return await withCheckedContinuation { c in thinDoc.autosave { c.resume(returning: $0) } }
        }
        check(await autosave("t1\n"), "first autosave")
        check(disk(thinURL) == "t1\n", "first autosave wrote the file")
        check(thinOriginals().count == 1, "first autosave after opening keeps a copy")
        check(await autosave("t2\n"), "second autosave")
        check(disk(thinURL) == "t2\n", "second autosave wrote the file")
        check(thinOriginals().count == 1, "an autosave within 60 s of the last copy adds none")
        thinDoc.text = "t3\n"
        thinDoc.updateChangeCount(.done)
        check(await save(thinDoc), "explicit save after autosaves")
        let thinCopies = thinOriginals()
        check(thinCopies.count == 2 && thinCopies.first.flatMap { store.data(for: $0) } == Data("t2\n".utf8),
              "an explicit save keeps the autosaved version")
        AppSettings.saveAutomatically = false
        await close(thinDoc)
    }
}
#endif
