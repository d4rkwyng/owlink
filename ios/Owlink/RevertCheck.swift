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
        let copies2 = SaveSafetyStores.copies.copies(forDocumentPath: doc.recoveryPath)
        info("safety copies now: \(copies2.map { "\($0.kind.rawValue) \($0.byteCount)b \(String(data: SaveSafetyStores.copies.data(for: $0) ?? Data(), encoding: .utf8)?.debugDescription ?? "")" })")
        if let c = copies2.first(where: { $0.kind == .original }) {
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
    }
}
#endif
