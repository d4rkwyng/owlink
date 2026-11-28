import AppKit
import CedricCore

/// CEDRIC_CHECK=binary (tools-check): a file of bytes 0…255 opens with the
/// "This looks like a binary file" bar and nothing shown; ⌘S does nothing
/// and the file is unchanged; Open Anyway shows it read-only (typing
/// changes nothing, Save still off); Allow Editing makes it a text tab.
/// An Open Anyway whose read fails leaves the tab held (no Allow Editing,
/// no save, the file as it was); the next one, the file readable, shows it.
/// A UTF-16 file and a log with escape codes open as text, with no bar; a
/// .crt of junk bytes is held as binary with no Certificate panel.
@MainActor
extension DevChecks {
    static func binaryCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard name == "binary" else { return false }
        let bin = dir.appendingPathComponent("binary.bin")
        let bytes = Data((0..<4).flatMap { _ in (0...255).map { UInt8($0) } })
        try? bytes.write(to: bin)
        let utf16 = dir.appendingPathComponent("utf16.txt")
        try? (Data([0xFF, 0xFE]) + "Hello from UTF-16\n".data(using: .utf16LittleEndian)!).write(to: utf16)
        let ansi = write("build.log", String(repeating: "\u{1B}[32mok\u{1B}[0m step done\n", count: 20))
        guard let tab = app.open(bin) else { expect(false, "opened binary.bin"); finish(); return true }
        sized(tab)
        func saveItem() -> NSMenuItem? { menuItem("s", [.command]) }
        var junk: EditorWindowController?
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                tab.window?.makeKeyAndOrderFront(nil)
                tab.window?.makeFirstResponder(tab.textView)
                expect(tab.binary == .held(tab.binaryHeldText ?? ""), "binary.bin is held, not shown", "\(String(describing: tab.binary).prefix(40))")
                expect(tab.text.isEmpty, "nothing shown before Open Anyway", "\(tab.text.count) characters")
                expect(tab.binaryBar?.isHidden == false && tab.binaryBar?.button.title == "Open Anyway",
                       "the bar says so, with Open Anyway", tab.binaryBar?.label.stringValue ?? "no bar")
                expect(saveItem().map { app.validateMenuItem($0) } == false, "Save is off")
                key("s", [.command])
                expect((try? Data(contentsOf: bin)) == bytes, "⌘S left the file's bytes alone")
            },
            snapshot("binary-1-held.png"),
            sync {
                // 0.6.1 review: the open skipped the decode, so Open Anyway
                // reads the file now. That read failing (here: no read
                // permission) must leave the tab held. Shown read-only with
                // empty text and marked saved, Allow Editing and ⌘S wrote
                // an empty file over the original (its stamp unchanged).
                expect(tab.binaryHeldText == "", "the open decoded nothing: Open Anyway has the read to do")
                let mode = (try? FileManager.default.attributesOfItem(atPath: bin.path)[.posixPermissions] as? NSNumber)?.uint16Value ?? 0o644
                chmod(bin.path, 0)
                tab.binaryBar?.button.performClick(nil)
                expect(tab.binary == .held(""), "Open Anyway's read fails: the tab stays held", "\(String(describing: tab.binary).prefix(40))")
                let sheet = tab.window?.attachedSheet
                expect(sheet != nil, "the read error is shown")
                if let sheet { tab.window?.endSheet(sheet) }
                expect(tab.text.isEmpty && !tab.textView.isEditable && !tab.doc.isDirty, "nothing shown, nothing to edit")
                expect(tab.binaryBar?.isHidden == false && tab.binaryBar?.button.title == "Open Anyway",
                       "the bar still offers Open Anyway, not Allow Editing", tab.binaryBar?.button.title ?? "no bar")
                tab.allowBinaryEditing()
                expect(tab.binary == .held("") && !tab.textView.isEditable, "Allow Editing does nothing while held")
                expect(saveItem().map { app.validateMenuItem($0) } == false, "Save stays off")
                key("s", [.command])
                expect(!tab.save(), "and save() refuses")
                let size = (try? FileManager.default.attributesOfItem(atPath: bin.path)[.size] as? NSNumber)?.intValue
                expect(size == bytes.count, "the unreadable file keeps its size", "\(size ?? -1) bytes")
                chmod(bin.path, mode)
                expect((try? Data(contentsOf: bin)) == bytes, "and its bytes, readable again")
                expect(tab.binaryHeldText == "", "still nothing decoded: the retry reads the file")
            },
            sync {
                tab.binaryBar?.button.performClick(nil)
                expect(tab.binary == .readOnly, "Open Anyway again, the file readable: read-only")
                expect(tab.text.count > 900, "the bytes show as text", "\(tab.text.count) characters")
                expect(!tab.textView.isEditable, "the text view is read-only")
                let before = tab.text
                key("x")
                expect(tab.text == before && !tab.doc.isDirty, "typing changes nothing")
                expect(saveItem().map { app.validateMenuItem($0) } == false, "Save is still off")
                expect(!tab.save() && (try? Data(contentsOf: bin)) == bytes, "and saving writes nothing")
                expect(tab.binaryBar?.button.title == "Allow Editing", "the bar offers Allow Editing")
            },
            snapshot("binary-2-readonly.png"),
            sync {
                tab.binaryBar?.button.performClick(nil)
                expect(tab.binary == .editable && tab.textView.isEditable, "Allow Editing: editable")
                expect(tab.binaryBar?.isHidden == true, "the bar goes")
                expect(saveItem().map { app.validateMenuItem($0) } == true, "Save is on")
                tab.doc.markSaved()
            },
            sync {
                for url in [utf16, ansi] {
                    guard let t = app.open(url) else { expect(false, "opened \(url.lastPathComponent)"); continue }
                    expect(t.binary == nil && t.binaryBar == nil && !t.text.isEmpty, "\(url.lastPathComponent) opens as text, no bar",
                           String(t.text.prefix(30)))
                }
                // A .crt that is neither DER nor PEM: the binary bar, no certificate tab or panel.
                let crt = dir.appendingPathComponent("junk.crt")
                try? bytes.write(to: crt)
                let before = app.certificateTabs.count
                junk = app.open(crt)
                expect(junk?.binary == .held(junk?.binaryHeldText ?? "") && app.certificateTabs.count == before,
                       "junk.crt is held as binary, not a certificate tab")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                // The Certificate panel would open a turn after the open.
                expect(junk?.previewPane == nil, "and gets no Certificate panel")
            },
            sync {
                // Security audit L2: a named pipe and /dev/zero are refused
                // before a byte is read (the check would hang otherwise).
                let fifo = dir.appendingPathComponent("pipe.txt")
                mkfifo(fifo.path, 0o600)
                let count = app.tabs.count
                let start = Date()
                AppDelegate.lastSpecialRefusal = nil
                expect(app.open(fifo) == nil && AppDelegate.lastSpecialRefusal?.contains("named pipe") == true,
                       "a named pipe is refused", AppDelegate.lastSpecialRefusal ?? "-")
                AppDelegate.lastSpecialRefusal = nil
                expect(app.open(URL(fileURLWithPath: "/dev/zero")) == nil && AppDelegate.lastSpecialRefusal?.contains("device") == true,
                       "/dev/zero is refused", AppDelegate.lastSpecialRefusal ?? "-")
                expect(app.tabs.count == count && Date().timeIntervalSince(start) < 1, "no tab, no hang")
                // Security audit M1(b): extreme line and column numbers clamp.
                let t = app.open(utf16)!
                t.goToLine(Int.min, column: Int.min)
                expect(t.textView.selectedRange().location == 0, "line Int.min goes to the start")
                t.goToLine(Int.max, column: Int.max)
                expect(t.textView.selectedRange().location == (t.text as NSString).length, "line Int.max goes to the end",
                       "\(t.textView.selectedRange().location)")
            },
            sync {
                // Security audit L1: saving through a symbolic link writes the
                // target and keeps the link and the target's 0600.
                let target = write("real/secret.env", "A=1\n")
                chmod(target.path, 0o600)
                let link = dir.appendingPathComponent("secret-link.env")
                try? FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "real/secret.env")
                guard let t = app.open(link) else { expect(false, "opened the link"); return }
                sized(t)
                focus(t)
                t.textView.setSelectedRange(NSRange(location: (t.text as NSString).length, length: 0))
                type("B=2\n")
                key("s", [.command])
                let fm = FileManager.default
                let mode = (try? fm.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
                expect((try? fm.destinationOfSymbolicLink(atPath: link.path)) == "real/secret.env", "⌘S through a link: still a link")
                expect((try? String(contentsOf: target, encoding: .utf8)) == "A=1\nB=2\n", "the target has the new text")
                expect(mode == 0o600, "and keeps mode 600", String(mode, radix: 8))
                expect(!t.doc.isDirty, "the tab is saved")
            },
        ]
        steps += steps2
        run(steps)
        return true
    }
}

extension EditorWindowController {
    /// The text waiting for Open Anyway (checks).
    var binaryHeldText: String? { if case .held(let t) = binary { return t } else { return nil } }
}
