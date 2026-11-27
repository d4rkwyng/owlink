import AppKit
import CedricCore

/// CEDRIC_CHECK=filenotices: the two file bars (FileNotices.swift).
///
/// Not valid UTF-8: the QA's invalid-utf8.txt opens as Latin-1 under a bar
/// that says so, the status bar says "Latin-1 (guessed)", and nothing is
/// unsaved. The bar's Reopen with Encoding… and Format › Reopen with
/// Encoding… (⌥⇧⌘R) open the same picker; picking Windows-1252 reads the
/// file again as that (no longer a guess, the bar goes). Keep, on another
/// such file: the guess is the user's, the bar goes, nothing to save.
///
/// Mixed line endings: the bar says "mostly LF" with Convert to LF and
/// Keep Mixed; the status bar says "LF (mixed)". Edits in the middle (a
/// typed line, a changed line, a joined pair) save with every other
/// line's own ending, byte for byte; undone and saved again, the file's
/// bytes again (each save checked to have written the file). Keep Mixed
/// hides the bar and saving still keeps them. Convert to LF (one undo
/// step) writes all LF; ⌘Z brings mixed back; the status bar's CRLF
/// writes all CRLF.
///
/// Then, each through ⌘S (or Save As) and the file's bytes: a break
/// belongs to its "\n", not to what its line says (two lines alike, the
/// first deleted); a CR left straight before an LF is written so it
/// doesn't read back as one CRLF; the only CRLF deleted, saved, undone
/// and saved again comes back (and redo, undo again); typing then deleting
/// across a CRLF undoes in steps that each change the text; Save As keeps
/// them; a tab closed unsaved and brought back with ⇧⌘T after its file
/// was moved away keeps them (from what was kept, not the file); Revert
/// to Saved after the file was rewritten with one kind, then ⌘Z: the
/// edited text's own breaks again; Revert to the same words saved with a
/// BOM, then ⌘Z: no BOM again, unsaved, and saved without one. Picking the guessed encoding from the
/// status bar's Save with Encoding settles the guess, as Keep does.
extension DevChecks {
    static func fileNoticesCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard name == "filenotices" else { return false }
        func bytes(_ u: URL) -> [UInt8] { (try? Data(contentsOf: u)).map { [UInt8]($0) } ?? [] }
        func put(_ name: String, _ b: [UInt8]) -> URL {
            let u = dir.appendingPathComponent(name)
            try? Data(b).write(to: u)
            return u
        }
        func show(_ b: [UInt8]) -> String { String(decoding: b, as: UTF8.self).debugDescription }
        // "café", then ÿþ: not UTF-8.
        let invalid = put("invalid-utf8.txt", [0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFF, 0xFE, 0x0A])
        let invalid2 = put("invalid-keep.txt", [0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0A])
        let mixedBytes = Array("one\r\ntwo\nthree\rfour\r\nfive\nsix\n".utf8)
        let mixed = put("mixed-endings.txt", mixedBytes)
        var pickers: [(titles: [String], anchor: NSView)] = []
        EditorWindowController.checkEncodingPicker = { menu, view in pickers.append((menu.items.map(\.title), view)) }
        guard let tab = app.open(invalid) else { expect(false, "opened invalid-utf8.txt"); finish(); return true }
        sized(tab)
        let edited = Array("one\r\ntwo\nnew\nthree!\rfourfive\nsix\n".utf8)
        /// A typed line after "two", "three" changed, "four" and "five" joined.
        func edit(_ m: EditorWindowController) {
            focus(m)
            let ns = { m.text as NSString }
            m.textView.setSelectedRange(NSRange(location: NSMaxRange(ns().range(of: "two")), length: 0))
            key("\r"); type("new")
            m.textView.setSelectedRange(NSRange(location: NSMaxRange(ns().range(of: "three")), length: 0))
            type("!")
            m.textView.setSelectedRange(NSRange(location: ns().range(of: "five").location, length: 0))
            key("\u{7f}")
        }
        var keepTab: EditorWindowController?
        var mixedTab: EditorWindowController?
        let encodings = TextEncoding.allCases.map(\.displayName)
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                focus(tab)
                expect(tab.doc.encoding == .latin1 && tab.doc.encodingGuessed, "invalid UTF-8 opens as Latin-1, a guess",
                       "\(tab.doc.encoding) \(tab.doc.encodingGuessed)")
                let bar = tab.encodingBar
                expect(bar?.isHidden == false && bar?.label.stringValue == "This file isn’t valid UTF-8, so Owlink opened it as Latin-1 (a guess).",
                       "the bar says so", bar?.label.stringValue ?? "no bar")
                expect(bar?.button("Reopen with Encoding…") != nil && bar?.button("Keep") != nil, "…with Reopen with Encoding… and Keep")
                expect(tab.statusBar.encodingButton.title == "Latin-1 (guessed)", "the status bar says Latin-1 (guessed)",
                       tab.statusBar.encodingButton.title)
                expect(!tab.doc.isDirty && tab.window?.attachedSheet == nil, "nothing unsaved, no sheet: the text is editable",
                       "\(tab.doc.isDirty)")
                expect(tab.textView.isEditable, "…and typing works")
                expect(tab.lineEndingBar == nil || tab.lineEndingBar?.isHidden == true, "no mixed line endings bar")
            },
            snapshot("filenotices-encoding.png"),
            sync {
                if let b = tab.encodingBar?.button("Reopen with Encoding…") { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }
                expect(pickers.count == 1 && pickers.first?.anchor === tab.encodingBar?.button("Reopen with Encoding…"),
                       "the bar's button opens the picker under itself", "\(pickers.count)")
                let item = menuItem("r", [.command, .option, .shift])
                expect(item?.title == "Reopen with Encoding…" && item?.menu?.title == "Format",
                       "Format › Reopen with Encoding… is ⌥⇧⌘R", "\(item?.title ?? "none") in \(item?.menu?.title ?? "-")")
                key("r", [.command, .option, .shift])
                expect(pickers.count == 2 && pickers.last?.anchor === tab.statusBar.encodingButton,
                       "⌥⇧⌘R opens the picker under the status bar's encoding", "\(pickers.count)")
                expect(pickers.count == 2 && pickers[0].titles == pickers[1].titles && pickers[0].titles == ["Reopen with Encoding"] + encodings,
                       "…the same picker: every encoding", "\(pickers.map(\.titles))")
                // Pick Windows-1252 from it.
                let menu = tab.reopenEncodingMenu()
                expect(menu.items.first { $0.state == .on }?.title == TextEncoding.latin1.displayName, "the guess is ticked")
                if let w = menu.items.first(where: { $0.title == TextEncoding.windows1252.displayName }) {
                    menu.performActionForItem(at: menu.index(of: w))
                }
                expect(tab.doc.encoding == .windows1252 && !tab.doc.encodingGuessed, "picking Windows-1252 reads it as that, no longer a guess")
                expect(tab.encodingBar?.isHidden == true, "…the bar goes")
                expect(tab.statusBar.encodingButton.title == "Windows-1252 (Western)", "…the status bar names it",
                       tab.statusBar.encodingButton.title)
                expect(!tab.doc.isDirty, "…and nothing is unsaved")
            },
            sync {
                keepTab = app.open(invalid2)
                guard let k = keepTab else { expect(false, "opened invalid-keep.txt"); return }
                focus(k)
                expect(k.encodingBar?.isHidden == false && k.statusBar.encodingButton.title == "Latin-1 (guessed)", "another guess: the bar again")
                if let b = k.encodingBar?.button("Keep") { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }
                expect(k.encodingBar?.isHidden == true && !k.doc.encodingGuessed, "Keep: the bar goes, the guess is the user's")
                expect(k.statusBar.encodingButton.title == TextEncoding.latin1.displayName, "…the status bar drops (guessed)",
                       k.statusBar.encodingButton.title)
                expect(!k.doc.isDirty && bytes(invalid2) == [0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0A], "…nothing to save, the file untouched")
            },
            sync {
                mixedTab = app.open(mixed)
                guard let m = mixedTab else { expect(false, "opened mixed-endings.txt"); return }
                sized(m)
                focus(m)
                let bar = m.lineEndingBar
                expect(bar?.isHidden == false && bar?.label.stringValue == "This file has mixed line endings (mostly LF).",
                       "mixed line endings: the bar says so", bar?.label.stringValue ?? "no bar")
                expect(bar?.button("Convert to LF") != nil && bar?.button("Keep Mixed") != nil, "…with Convert to LF and Keep Mixed")
                expect(m.statusBar.lineEndingButton.title == "LF (mixed)", "the status bar says LF (mixed)", m.statusBar.lineEndingButton.title)
                expect(m.encodingBar == nil || m.encodingBar?.isHidden == true, "no encoding bar on UTF-8")
                expect(!m.doc.isDirty, "nothing unsaved")
            },
            snapshot("filenotices-mixed.png"),
            sync {
                guard let m = mixedTab else { return }
                edit(m)
                expect(m.text == "one\ntwo\nnew\nthree!\nfourfive\nsix\n", "edited in the middle", m.text.debugDescription)
                key("s", [.command])
                expect(bytes(mixed) == edited && !m.doc.isDirty, "⌘S writes the edit, each line's own ending", show(bytes(mixed)))
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                guard let m = mixedTab, let um = m.textView.undoManager else { expect(false, "the mixed tab has an undo manager"); return }
                var n = 0
                while um.canUndo, n < 20, m.text != "one\ntwo\nthree\nfour\nfive\nsix\n" { um.undo(); n += 1 }
                expect(m.text == "one\ntwo\nthree\nfour\nfive\nsix\n", "undo brings the text back", m.text.debugDescription)
            },
            sync {
                // (Unsaved is noted a turn after an undo.) The edit is on disk: the save below has to write.
                guard let m = mixedTab else { return }
                expect(m.doc.isDirty && bytes(mixed) == edited, "undone past the save: unsaved, the edit still on disk")
                key("s", [.command])
                expect(bytes(mixed) == mixedBytes, "undone and saved: the file's bytes, byte for byte", show(bytes(mixed)))
                expect(!m.doc.isDirty, "…saved")
            },
            sync {
                guard let m = mixedTab else { return }
                edit(m)
                key("s", [.command])
                // Each line its own ending; the typed line LF (the most common);
                // the joined line the second's (five's LF; four's CRLF went with the join).
                expect(bytes(mixed) == edited, "⌘S keeps each line's ending, the typed line LF", show(bytes(mixed)))
                expect(m.doc.mixedLineEndings && m.statusBar.lineEndingButton.title == "LF (mixed)", "…still mixed after the save")
            },
            sync {
                guard let m = mixedTab else { return }
                if let b = m.lineEndingBar?.button("Keep Mixed") { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }
                expect(m.lineEndingBar?.isHidden == true && m.doc.mixedLineEndings && !m.doc.isDirty,
                       "Keep Mixed: the bar goes, still mixed, nothing to save")
                m.textView.setSelectedRange(NSRange(location: (m.text as NSString).length, length: 0))
                type("seven")
                key("s", [.command])
                expect(bytes(mixed) == edited + Array("seven".utf8), "…and saving keeps them", show(bytes(mixed)))
            },
            sync {
                // A fresh tab on the file: Convert to LF from the bar.
                guard let m = mixedTab else { return }
                m.window?.performClose(nil)
                mixedTab = app.open(mixed)
                guard let c = mixedTab else { expect(false, "reopened mixed-endings.txt"); return }
                focus(c)
                expect(c.lineEndingBar?.isHidden == false, "reopened: the bar again")
                if let b = c.lineEndingBar?.button("Convert to LF") { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }
                expect(c.lineEndingBar?.isHidden == true && !c.doc.mixedLineEndings && c.doc.isDirty,
                       "Convert to LF: the bar goes, unsaved until saved")
                expect(c.statusBar.lineEndingButton.title == "LF", "…the status bar says LF", c.statusBar.lineEndingButton.title)
                c.textView.undoManager?.undo()
                expect(c.doc.mixedLineEndings && c.statusBar.lineEndingButton.title == "LF (mixed)" && c.doc.lineBreaks != nil,
                       "⌘Z: mixed again, its own endings back", c.statusBar.lineEndingButton.title)
                c.textView.undoManager?.redo()
                key("s", [.command])
                expect(bytes(mixed) == Array("one\ntwo\nnew\nthree!\nfourfive\nsix\nseven".utf8), "saved: all LF", show(bytes(mixed)))
            },
            sync {
                guard let c = mixedTab else { return }
                // A mixed file again; the status bar's CRLF writes all CRLF.
                let again = put("mixed-crlf.txt", mixedBytes)
                c.window?.performClose(nil)
                mixedTab = app.open(again)
                guard let s = mixedTab else { expect(false, "opened mixed-crlf.txt"); return }
                focus(s)
                let item = s.statusBar.lineEndingButton.menu?.items.first { ($0.representedObject as? String) == LineEnding.crlf.rawValue }
                if let item, let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
                expect(s.lineEndingBar?.isHidden == true && s.statusBar.lineEndingButton.title == "CRLF", "the status bar's CRLF: picked, no bar")
                key("s", [.command])
                expect(bytes(again) == Array("one\r\ntwo\r\nthree\r\nfour\r\nfive\r\nsix\r\n".utf8), "saved: all CRLF", show(bytes(again)))
                EditorWindowController.checkEncodingPicker = nil
                s.window?.performClose(nil)
            },
        ]
        steps += steps2
        steps += mixedSaveSteps(app)
        let steps3: [Step] = [
            sync {
                // Save with Encoding › the guessed one: the user's now, as Keep.
                guard let g = app.open(put("invalid-pick.txt", [0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0A])) else { expect(false, "opened invalid-pick.txt"); return }
                focus(g)
                expect(g.doc.encodingGuessed && g.encodingBar?.isHidden == false, "a guessed encoding again, with its bar")
                let item = g.statusBar.encodingButton.menu?.items.first { ($0.representedObject as? String) == "save:" + g.doc.encoding.rawValue }
                expect(item != nil, "the status bar's Save with Encoding lists the guess")
                if let item, let menu = item.menu { menu.performActionForItem(at: menu.index(of: item)) }
                expect(!g.doc.encodingGuessed && g.encodingBar?.isHidden == true, "picking the guessed encoding settles it: the bar goes")
                expect(g.statusBar.encodingButton.title == TextEncoding.latin1.displayName && !g.doc.isDirty,
                       "…the status bar drops (guessed), nothing to save", g.statusBar.encodingButton.title)
            },
        ]
        steps += steps3
        run(steps)
        return true
    }
}

extension DevChecks {
    /// Mixed line endings through real saves (FileNoticesCheck's second half).
    static func mixedSaveSteps(_ app: AppDelegate) -> [(@escaping () -> Void) -> Void] {
        func bytes(_ u: URL) -> [UInt8]? { (try? Data(contentsOf: u)).map { [UInt8]($0) } }
        func put(_ name: String, _ s: String) -> URL {
            let u = dir.appendingPathComponent(name)
            try? Data(s.utf8).write(to: u)
            return u
        }
        func show(_ b: [UInt8]?) -> String { b.map { String(decoding: $0, as: UTF8.self).debugDescription } ?? "no file" }
        func b(_ s: String) -> [UInt8] { Array(s.utf8) }
        /// Selects `r` and presses delete (backspace).
        func delete(_ t: EditorWindowController, _ r: NSRange) {
            t.textView.setSelectedRange(r)
            key("\u{7f}")
        }
        func open(_ name: String, _ s: String) -> EditorWindowController? {
            guard let t = app.open(put(name, s)) else { expect(false, "opened \(name)"); return nil }
            sized(t)
            focus(t)
            return t
        }
        func close(_ t: EditorWindowController?) {
            t?.doc.markSaved()
            t?.window?.performClose(nil)
        }
        var tab: EditorWindowController?
        let crlfOnce = "a\r\nb\nc\nd\n"
        var moved: URL?
        var stepsChanged: [Bool] = []
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                // Two lines alike: deleting the first and its CRLF keeps the second's own LF.
                guard let t = open("alike.txt", "x\r\nx\nz") else { return }
                tab = t
                expect(t.doc.mixedLineEndings, "x\\r\\nx\\nz is mixed")
                delete(t, NSRange(location: 0, length: 2))
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b("x\nz"), "a break is its own \\n's, not its line's: x\\nz", show(bytes(t.doc.fileURL!)))
                close(t)
            },
            sync {
                // A\rB\nC, B deleted: the CR before the LF is written as CRLF, so three lines read back.
                guard let t = open("merge.txt", "A\rB\nC") else { return }
                delete(t, NSRange(location: 2, length: 1))
                key("s", [.command])
                let out = bytes(t.doc.fileURL!)
                expect(out == b("A\r\n\nC"), "a CR left before an LF doesn't merge with it", show(out))
                expect(out.flatMap { TextCodec.decode(Data($0))?.text } == "A\n\nC", "…reopened, still three lines")
                close(t)
            },
            sync {
                // The only CRLF deleted (backspace at the start of b), saved.
                guard let t = open("crlf-once.txt", crlfOnce) else { return }
                tab = t
                t.textView.setSelectedRange(NSRange(location: 2, length: 0))
                key("\u{7f}")
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b("ab\nc\nd\n") && !t.doc.isDirty, "the only CRLF deleted and saved",
                       show(bytes(t.doc.fileURL!)))
            },
            sync {
                guard let t = tab, let um = t.textView.undoManager else { expect(false, "crlf-once: an undo manager"); return }
                um.undo()
            },
            sync {
                guard let t = tab, let um = t.textView.undoManager else { expect(false, "crlf-once: an undo manager"); return }
                expect(t.text == "a\nb\nc\nd\n" && t.doc.isDirty, "⌘Z after the save: the break back, unsaved", t.text.debugDescription)
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b(crlfOnce), "saved again: the CRLF is back, byte for byte", show(bytes(t.doc.fileURL!)))
                um.redo()
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b("ab\nc\nd\n"), "redo and save: deleted again", show(bytes(t.doc.fileURL!)))
                um.undo()
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b(crlfOnce), "undo and save again: the CRLF again", show(bytes(t.doc.fileURL!)))
                close(t)
            },
            sync {
                // Typing, then deleting back across the CRLF: each ⌘Z changes the text, and all of them give the file back.
                guard let t = open("crlf-typing.txt", crlfOnce) else { return }
                tab = t
                t.textView.setSelectedRange(NSRange(location: 2, length: 0))
                type("xy")
            },
            // Each key in its own turn, as a person types: coalesced into one undo step by NSTextView.
            sync { key("\u{7f}") },
            sync { key("\u{7f}") },
            sync { key("\u{7f}") },
            sync {
                guard let t = tab else { return }
                expect(t.text == "ab\nc\nd\n", "typed and deleted back across the CRLF", t.text.debugDescription)
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b("ab\nc\nd\n"), "…saved", show(bytes(t.doc.fileURL!)))
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                guard let t = tab, let um = t.textView.undoManager else { expect(false, "crlf-typing: an undo manager"); return }
                stepsChanged = []
                var n = 0
                while um.canUndo, n < 10, t.text != "a\nb\nc\nd\n" {
                    let before = t.text
                    um.undo()
                    stepsChanged.append(t.text != before)
                    n += 1
                }
                expect(t.text == "a\nb\nc\nd\n" && !stepsChanged.isEmpty && !stepsChanged.contains(false),
                       "every ⌘Z changes the text (no step that only gives a break back)", "\(stepsChanged) \(t.text.debugDescription)")
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b(crlfOnce), "…undone and saved: the CRLF back", show(bytes(t.doc.fileURL!)))
                close(t)
            },
            sync {
                // Save As: a new file with each break as it was.
                guard let t = open("saveas-src.txt", "one\r\ntwo\nthree\rfour\r\n") else { return }
                t.textView.setSelectedRange(NSRange(location: 7, length: 0))
                type("!")
                let target = dir.appendingPathComponent("saveas-out.txt")
                try? FileManager.default.removeItem(at: target)
                EditorWindowController.checkSaveAsURL = target
                t.saveAs()
                expect(bytes(target) == b("one\r\ntwo!\nthree\rfour\r\n") && t.doc.fileURL == target,
                       "Save As writes each break as it was", show(bytes(target)))
                close(t)
            },
            sync {
                // Closed unsaved, the file moved away, ⇧⌘T: the breaks come from what was kept.
                guard let t = open("closed-mixed.txt", "one\r\ntwo\nthree\rfour\r\n") else { return }
                t.textView.setSelectedRange(NSRange(location: 13, length: 0))
                key("\r")
                type("new")
                expect(t.text == "one\ntwo\nthree\nnew\nfour\n" && t.doc.isDirty, "typed a line after the CR", t.text.debugDescription)
                let url = t.doc.fileURL!
                key("w", [.command])
                let away = dir.appendingPathComponent("closed-mixed-moved.txt")
                try? FileManager.default.removeItem(at: away)
                try? FileManager.default.moveItem(at: url, to: away)
                moved = away
            },
            sync {
                key("t", [.command, .shift])
            },
            sync {
                guard let r = app.tabs.last, r.doc.displayName == "closed-mixed.txt" else { expect(false, "⇧⌘T brought closed-mixed.txt back"); return }
                expect(r.text == "one\ntwo\nthree\nnew\nfour\n" && r.doc.isDirty && r.doc.mixedLineEndings,
                       "⇧⌘T: the unsaved text, still mixed", r.text.debugDescription)
                let target = dir.appendingPathComponent("closed-mixed-saved.txt")
                try? FileManager.default.removeItem(at: target)
                EditorWindowController.checkSaveAsURL = target
                r.saveAs()
                expect(bytes(target) == b("one\r\ntwo\nthree\r\nnew\rfour\r\n"),
                       "…saved: each break as it was, the file it came from gone", show(bytes(target)))
                _ = moved
                close(r)
            },
            sync {
                // Revert to Saved after the file was rewritten all LF, then ⌘Z: the edited text's own breaks.
                guard let t = open("revert-mixed.txt", "one\r\ntwo\nthree\rfour\r\n") else { return }
                tab = t
                t.textView.setSelectedRange(NSRange(location: 3, length: 0))
                type("!")
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            sync {
                // Its own event, as from the menu: one undo step of its own.
                guard let t = tab else { return }
                try? Data(b("plain\nlf\n")).write(to: t.doc.fileURL!)
                app.revertToSaved(nil)
                expect(t.text == "plain\nlf\n" && !t.doc.mixedLineEndings, "Revert to Saved: the file as it is now (one kind)", t.text.debugDescription)
            },
            sync {
                guard let t = tab, let um = t.textView.undoManager else { expect(false, "revert: an undo manager"); return }
                um.undo()
                expect(t.text == "one!\ntwo\nthree\nfour\n" && t.doc.mixedLineEndings, "⌘Z: the edited text, mixed again", t.text.debugDescription)
                let target = dir.appendingPathComponent("revert-mixed-saved.txt")
                try? FileManager.default.removeItem(at: target)
                EditorWindowController.checkSaveAsURL = target
                t.saveAs()
                expect(bytes(target) == b("one!\r\ntwo\nthree\rfour\r\n"), "…saved: its own breaks", show(bytes(target)))
                close(t)
            },
            // Revert, ⌘Z, ⌘⇧Z, ⌘Z: the edited text's breaks every time (the
            // redo's record read the map after its text change had taken
            // the breaks out, and the next ⌘Z set that stripped map).
            sync {
                guard let t = open("revert-cycle.txt", "one\r\ntwo\nthree\rfour\r\n") else { return }
                tab = t
                t.textView.setSelectedRange(NSRange(location: 3, length: 0))
                type("!")
            },
            sync {
                guard let t = tab else { return }
                try? Data(b("plain\nlf\n")).write(to: t.doc.fileURL!)
                app.revertToSaved(nil)
            },
            sync { tab?.textView.undoManager?.undo() },
            sync { tab?.textView.undoManager?.redo() },
            sync {
                guard let t = tab else { return }
                expect(t.text == "plain\nlf\n" && !t.doc.mixedLineEndings, "Revert, ⌘Z, ⌘⇧Z: the file's text, one kind",
                       t.text.debugDescription)
                t.textView.undoManager?.undo()
            },
            sync {
                guard let t = tab else { return }
                expect(t.text == "one!\ntwo\nthree\nfour\n" && t.doc.mixedLineEndings, "…⌘Z again: the edited text, mixed",
                       t.text.debugDescription)
                let target = dir.appendingPathComponent("revert-cycle-saved.txt")
                try? FileManager.default.removeItem(at: target)
                EditorWindowController.checkSaveAsURL = target
                t.saveAs()
                expect(bytes(target) == b("one!\r\ntwo\nthree\rfour\r\n"), "…saved: still its own breaks", show(bytes(target)))
                close(t)
            },
            // Revert to the same words saved with a BOM, then ⌘Z: the
            // edited version's encoding (no BOM) comes back with its text,
            // unsaved by the encoding alone, and a save writes no BOM. Before
            // 0.6.1 the BOM stayed, the tab was clean, and ⌘S wrote one.
            sync {
                guard let t = open("revert-bom.txt", "draft\n") else { return }
                tab = t
                t.textView.setSelectedRange(NSRange(location: 5, length: 0))
                type("!")
            },
            sync {
                guard let t = tab else { return }
                try? Data([0xEF, 0xBB, 0xBF] + b("draft!\n")).write(to: t.doc.fileURL!)
                app.revertToSaved(nil)
                expect(t.text == "draft!\n" && t.doc.encoding == .utf8BOM && !t.doc.isDirty,
                       "Revert to Saved: the same words, UTF-8 with BOM, saved", "\(t.doc.encoding) \(t.doc.isDirty)")
            },
            sync { tab?.textView.undoManager?.undo() },
            sync {
                guard let t = tab else { return }
                expect(t.text == "draft!\n" && t.doc.encoding == .utf8 && t.doc.isDirty,
                       "⌘Z: the edited version's UTF-8 (no BOM), unsaved", "\(t.doc.encoding) \(t.doc.isDirty)")
                expect(t.statusBar.encodingButton.title == "UTF-8", "…and the status bar says so", t.statusBar.encodingButton.title)
                let target = dir.appendingPathComponent("revert-bom-saved.txt")
                try? FileManager.default.removeItem(at: target)
                EditorWindowController.checkSaveAsURL = target
                t.saveAs()
                expect(bytes(target) == b("draft!\n"), "…saved: no BOM", show(bytes(target)))
                close(t)
            },
            // Convert Indentation rewrites every line's leading whitespace in
            // one edit: each break stays its own (all of them became LF).
            sync {
                guard let t = open("indent-mixed.txt", "a\r\n    b\n\tc\r\n        d\r\n") else { return }
                tab = t
                t.doc.indentation = Indentation(usesTabs: false, width: 4)
                t.convertIndentation(toTabs: true)
                expect(t.text == "a\n\tb\n\tc\n\t\td\n", "converted to tabs", t.text.debugDescription)
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b("a\r\n\tb\n\tc\r\n\t\td\r\n"), "Convert Indentation keeps each break",
                       show(bytes(t.doc.fileURL!)))
                t.textView.undoManager?.undo()
            },
        ]
        steps += steps3
        let steps4: [Step] = [
            sync {
                guard let t = tab else { return }
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b("a\r\n    b\n\tc\r\n        d\r\n"), "…⌘Z and save: the file's bytes",
                       show(bytes(t.doc.fileURL!)))
                close(t)
            },
            // The odd CRLF deleted and Return typed in its place: the same
            // text, another break. Unsaved (it was clean, and autosave and
            // closing skipped it), until undone.
            sync {
                guard let t = open("dirty-break.txt", "a\r\nb\nc\n") else { return }
                tab = t
                t.textView.setSelectedRange(NSRange(location: 2, length: 0))
                key("\u{7f}")
            },
            sync { key("\r") },
            sync {
                guard let t = tab else { return }
                expect(t.text == "a\nb\nc\n", "the CRLF deleted and Return typed back: the saved text", t.text.debugDescription)
                expect(t.doc.isDirty && t.window?.isDocumentEdited == true, "…but unsaved: the break is an LF now",
                       "dirty \(t.doc.isDirty)")
                t.textView.undoManager?.undo()
            },
            sync { tab?.textView.undoManager?.undo() },
            sync {
                guard let t = tab else { return }
                expect(t.text == "a\nb\nc\n" && !t.doc.isDirty, "…undone: the CRLF back, saved again", "dirty \(t.doc.isDirty)")
                close(t)
            },
            // The status bar and the mixed bar follow the breaks there are.
            sync {
                guard let t = open("last-odd.txt", "a\r\nb\nc\n") else { return }
                tab = t
                expect(t.lineEndingBar?.isHidden == false, "mixed: the bar shows")
                t.textView.setSelectedRange(NSRange(location: 2, length: 0))
                key("\u{7f}")
                let title = t.statusBar.lineEndingButton.itemTitle(at: 0)
                expect(title == LineEnding.lf.displayName, "the last odd break gone: the status says LF, not mixed", title)
                expect(t.lineEndingBar?.isHidden != false, "…and the mixed bar goes")
                t.textView.undoManager?.undo()
            },
            sync {
                guard let t = tab else { return }
                let title = t.statusBar.lineEndingButton.itemTitle(at: 0)
                expect(title.contains("(mixed)"), "⌘Z: mixed again in the status", title)
                expect(t.lineEndingBar?.isHidden == false, "…and the bar is back", t.lineEndingBar?.label.stringValue ?? "no bar")
                close(t)
            },
            sync {
                // Mostly LF, one CRLF: every LF deleted leaves only the CRLF.
                guard let t = open("all-odd.txt", "a\nb\nc\r\nd") else { return }
                tab = t
                delete(t, NSRange(location: 1, length: 3))
                let title = t.statusBar.lineEndingButton.itemTitle(at: 0)
                expect(t.text == "ac\nd", "the LF breaks deleted", t.text.debugDescription)
                expect(title == LineEnding.crlf.displayName, "only CRLF left: the status says so, not \"LF (mixed)\"", title)
                expect(t.lineEndingBar?.isHidden != false, "…and there is no mixed bar")
                key("s", [.command])
                expect(bytes(t.doc.fileURL!) == b("ac\r\nd"), "…saved with its CRLF", show(bytes(t.doc.fileURL!)))
                close(t)
            },
        ]
        steps += steps4
        return steps
    }
}
