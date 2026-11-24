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
/// line's own ending, byte for byte; undone and saved, the file's bytes
/// again. Keep Mixed hides the bar and saving still keeps them. Convert to
/// LF (one undo step) writes all LF; ⌘Z brings mixed back; the status
/// bar's CRLF writes all CRLF.
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
        run([
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
            },
            sync {
                guard let m = mixedTab, let um = m.textView.undoManager else { return }
                var n = 0
                while um.canUndo, n < 20, m.text != "one\ntwo\nthree\nfour\nfive\nsix\n" { um.undo(); n += 1 }
                expect(m.text == "one\ntwo\nthree\nfour\nfive\nsix\n", "undo brings the text back", m.text.debugDescription)
                key("s", [.command])
                expect(bytes(mixed) == mixedBytes, "undone and saved: the file's bytes, byte for byte", show(bytes(mixed)))
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
            },
        ])
        return true
    }
}
