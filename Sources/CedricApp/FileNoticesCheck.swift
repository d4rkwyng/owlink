import AppKit
import CedricCore

/// CEDRIC_CHECK=filenotices: the file bars (FileNotices.swift).
///
/// Not valid UTF-8: the QA's invalid-utf8.txt opens as Latin-1 under a bar
/// that says so, the status bar says "Latin-1 (guessed)", and nothing is
/// unsaved. The bar's Reopen with Encoding… and Format › Reopen with
/// Encoding… (⌥⇧⌘R) open the same picker; picking Windows-1252 reads the
/// file again as that (no longer a guess, the bar goes). Keep, on another
/// such file: the guess is the user's, the bar goes, nothing to save.
extension DevChecks {
    static func fileNoticesCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard name == "filenotices" else { return false }
        func bytes(_ u: URL) -> [UInt8] { (try? Data(contentsOf: u)).map { [UInt8]($0) } ?? [] }
        func put(_ name: String, _ b: [UInt8]) -> URL {
            let u = dir.appendingPathComponent(name)
            try? Data(b).write(to: u)
            return u
        }
        // "café", then ÿþ: not UTF-8.
        let invalid = put("invalid-utf8.txt", [0x63, 0x61, 0x66, 0xE9, 0x0A, 0xFF, 0xFE, 0x0A])
        let invalid2 = put("invalid-keep.txt", [0x6E, 0x61, 0xEF, 0x76, 0x65, 0x0A])
        var pickers: [(titles: [String], anchor: NSView)] = []
        EditorWindowController.checkEncodingPicker = { menu, view in pickers.append((menu.items.map(\.title), view)) }
        guard let tab = app.open(invalid) else { expect(false, "opened invalid-utf8.txt"); finish(); return true }
        sized(tab)
        var keepTab: EditorWindowController?
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
                EditorWindowController.checkEncodingPicker = nil
            },
        ])
        return true
    }
}
