import AppKit
import CedricCore
import UniformTypeIdentifiers

// Format › Markdown: bold, italic, strikethrough, inline code and link
// (MarkdownFormat in CedricCore). Each is one undo step, and only for
// Markdown tabs.

extension EditorWindowController {
    var markdownEditable: Bool { doc.language == .markdown && textView.isEditable && !textView.hasMarkedText() }

    func toggleMarkdown(_ style: MarkdownFormat.Style) {
        guard markdownEditable else { NSSound.beep(); return }
        let e = MarkdownFormat.toggle(style, in: textView.string as NSString, selection: textView.selectedRange())
        let names: [MarkdownFormat.Style: String] = [.bold: String(localized: "Bold"), .italic: String(localized: "Italic"),
                                                     .strikethrough: String(localized: "Strikethrough"), .code: String(localized: "Inline Code")]
        apply(e, actionName: names[style] ?? "")
    }

    /// ⌘↩: checks or unchecks the task boxes on the selected lines.
    func toggleCheckboxes() {
        guard markdownEditable,
              let e = MarkdownLists.toggleTasks(in: textView.string as NSString, selection: textView.selectedRange()) else { NSSound.beep(); return }
        apply(e, actionName: String(localized: "Checkbox"))
    }

    /// Format › Markdown › Format Table: lines up the table at the caret
    /// (not in fenced code).
    func formatTable() {
        let sel = textView.selectedRange()
        guard markdownEditable, textView.inFence?(sel.location) != true,
              let e = MarkdownTable.format(in: textView.string as NSString, selection: sel) else { NSSound.beep(); return }
        apply(e, actionName: String(localized: "Format Table"))
    }

    /// The line commands (MarkdownBlocks in CedricCore): headings, lists,
    /// quote, code block, table and image link. Each is one undo step; nil
    /// from the transform (nothing to change) beeps.
    func markdownBlock(_ name: String, inCode: Bool = false, _ f: (NSString, NSRange) -> TextEdit?) {
        let sel = textView.selectedRange()
        guard markdownEditable, inCode || textView.inFence?(sel.location) != true,
              let e = f(textView.string as NSString, sel) else { NSSound.beep(); return }
        apply(e, actionName: name)
    }

    func markdownHeading(_ level: Int) {
        let name = level == 0 ? String(localized: "Body") : String(localized: "Heading \(level)")
        markdownBlock(name) { MarkdownBlocks.heading(level, in: $0, selection: $1) }
    }

    func markdownImage() {
        guard markdownEditable else { NSSound.beep(); return }
        let clip = NSPasteboard.general.string(forType: .string)
        apply(MarkdownBlocks.image(in: textView.string as NSString, selection: textView.selectedRange(), clipboard: clip),
              actionName: String(localized: "Image Link"))
    }

    func markdownLink() {
        guard markdownEditable else { NSSound.beep(); return }
        let clip = NSPasteboard.general.string(forType: .string)
        apply(MarkdownFormat.link(in: textView.string as NSString, selection: textView.selectedRange(), clipboard: clip),
              actionName: String(localized: "Link"))
    }
}

extension AppDelegate {
    @objc func markdownBoldMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.bold) }
    @objc func markdownItalicMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.italic) }
    @objc func markdownStrikethroughMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.strikethrough) }
    @objc func markdownCodeMenu(_ sender: Any?) { currentTab?.toggleMarkdown(.code) }
    @objc func markdownLinkMenu(_ sender: Any?) { currentTab?.markdownLink() }
    @objc func toggleCheckboxMenu(_ sender: Any?) { currentTab?.toggleCheckboxes() }
    @objc func formatTableMenu(_ sender: Any?) { currentTab?.formatTable() }
    @objc func markdownBodyMenu(_ sender: Any?) { currentTab?.markdownHeading(0) }
    @objc func markdownHeading1Menu(_ sender: Any?) { currentTab?.markdownHeading(1) }
    @objc func markdownHeading2Menu(_ sender: Any?) { currentTab?.markdownHeading(2) }
    @objc func markdownHeading3Menu(_ sender: Any?) { currentTab?.markdownHeading(3) }
    @objc func markdownBulletListMenu(_ sender: Any?) {
        currentTab?.markdownBlock(String(localized: "Bulleted List")) { MarkdownBlocks.list(.bullet, in: $0, selection: $1) }
    }
    @objc func markdownNumberedListMenu(_ sender: Any?) {
        currentTab?.markdownBlock(String(localized: "Numbered List")) { MarkdownBlocks.list(.numbered, in: $0, selection: $1) }
    }
    @objc func markdownQuoteMenu(_ sender: Any?) {
        currentTab?.markdownBlock(String(localized: "Quote")) { MarkdownBlocks.quote(in: $0, selection: $1) }
    }
    /// In fenced code too: that is where it takes the fences off.
    @objc func markdownCodeBlockMenu(_ sender: Any?) {
        currentTab?.markdownBlock(String(localized: "Code Block"), inCode: true) { MarkdownBlocks.codeBlock(in: $0, selection: $1) }
    }
    @objc func markdownTableMenu(_ sender: Any?) {
        currentTab?.markdownBlock(String(localized: "Insert Table")) { MarkdownBlocks.insertTable(in: $0, selection: $1) }
    }
    @objc func markdownImageMenu(_ sender: Any?) { currentTab?.markdownImage() }
    /// Format › Markdown › Insert Image… (the Context Bar's Image button).
    @objc func markdownInsertImageFileMenu(_ sender: Any?) { currentTab?.insertImageFiles() }

    static let markdownActions: Set<Selector> = [
        #selector(markdownBoldMenu(_:)), #selector(markdownItalicMenu(_:)), #selector(markdownStrikethroughMenu(_:)),
        #selector(markdownCodeMenu(_:)), #selector(markdownLinkMenu(_:)), #selector(toggleCheckboxMenu(_:)),
        #selector(formatTableMenu(_:)), #selector(markdownBodyMenu(_:)), #selector(markdownHeading1Menu(_:)),
        #selector(markdownHeading2Menu(_:)), #selector(markdownHeading3Menu(_:)), #selector(markdownBulletListMenu(_:)),
        #selector(markdownNumberedListMenu(_:)), #selector(markdownQuoteMenu(_:)), #selector(markdownCodeBlockMenu(_:)),
        #selector(markdownTableMenu(_:)), #selector(markdownImageMenu(_:)), #selector(markdownInsertImageFileMenu(_:)),
    ]

    func validateMarkdownItem(_ item: NSMenuItem) -> Bool? {
        guard let action = item.action, Self.markdownActions.contains(action) else { return nil }
        guard let tab = currentTab else { return false }
        return tab.doc.language == .markdown && tab.textView.isEditable
    }
}

/// Format › Markdown, built with the main menu.
@MainActor
func markdownMenu() -> NSMenuItem {
    submenu(String(localized: "Markdown"), [
        item(String(localized: "Bold"), #selector(AppDelegate.markdownBoldMenu(_:)), "b"),
        item(String(localized: "Italic"), #selector(AppDelegate.markdownItalicMenu(_:)), "i"),
        item(String(localized: "Strikethrough"), #selector(AppDelegate.markdownStrikethroughMenu(_:)), "x", [.command, .shift]),
        item(String(localized: "Inline Code"), #selector(AppDelegate.markdownCodeMenu(_:)), "`", [.control]),
        item(String(localized: "Link"), #selector(AppDelegate.markdownLinkMenu(_:)), "k"),
        item(String(localized: "Image Link"), #selector(AppDelegate.markdownImageMenu(_:))),
        // Image files from an open panel, copied in as paste and drop do (the Context Bar's Image button).
        item(String(localized: "Insert Image…"), #selector(AppDelegate.markdownInsertImageFileMenu(_:))),
        .separator(),
        // ⌘1–⌘3 as in Bear (plain ⌘1–3 were free; ⌃⌘1 is the folder sidebar, ⌥⌘1… Open Recent).
        item(String(localized: "Body"), #selector(AppDelegate.markdownBodyMenu(_:))),
        item(String(localized: "Heading 1"), #selector(AppDelegate.markdownHeading1Menu(_:)), "1"),
        item(String(localized: "Heading 2"), #selector(AppDelegate.markdownHeading2Menu(_:)), "2"),
        item(String(localized: "Heading 3"), #selector(AppDelegate.markdownHeading3Menu(_:)), "3"),
        .separator(),
        item(String(localized: "Bulleted List"), #selector(AppDelegate.markdownBulletListMenu(_:))),
        item(String(localized: "Numbered List"), #selector(AppDelegate.markdownNumberedListMenu(_:))),
        // "Checkbox", like its neighbours (and the Context Bar button): adds boxes, then checks and unchecks them.
        item(String(localized: "Checkbox"), #selector(AppDelegate.toggleCheckboxMenu(_:)), "\r"),
        item(String(localized: "Quote"), #selector(AppDelegate.markdownQuoteMenu(_:))),
        item(String(localized: "Code Block"), #selector(AppDelegate.markdownCodeBlockMenu(_:))),
        .separator(),
        item(String(localized: "Insert Table"), #selector(AppDelegate.markdownTableMenu(_:))),
        item(String(localized: "Format Table"), #selector(AppDelegate.formatTableMenu(_:))),
    ])
}

// Pasted and dropped images in Markdown: copied into an "images" folder
// next to the document (a file already inside the document's folder is
// linked where it is) and inserted as ![](images/name.png).

extension EditorWindowController {
    func insertImages(_ files: [URL], bitmap: Data?, at range: NSRange) {
        guard textView.isEditable else { NSSound.beep(); return }
        guard let docURL = doc.fileURL else { askToSaveForImages(files, bitmap: bitmap, at: range); return }
        let dir = docURL.deletingLastPathComponent()
        // A link to a file already in the folder, or a name published in "images".
        enum Piece { case inPlace(String), copied(String) }
        var pieces: [Piece] = []
        // "images" is opened once per batch beneath the pinned document
        // folder; every copy is staged and published as images/<name>
        // through descriptors (ImageStore; the kernel keeps the rename
        // beneath the folder, or on macOS 15 it is made relative to the
        // held "images", which must be a real folder): moving or replacing "images" can't redirect the
        // staging or the published file through it, nothing is overwritten,
        // and no partial file gets a final name.
        var opened: ImageStore?
        func store() throws -> ImageStore {
            if let opened { return opened }
            do {
                let s = try ImageStore.open(in: dir)
                opened = s
                return s
            } catch let failure as ImageStore.Failure {
                throw Self.imageStoreError(failure)
            }
        }
        do {
            for f in files {
                // Only a regular file is linked in place (not a folder named x.png).
                if let rel = MarkdownPaste.relativePath(of: f, from: dir) {
                    guard SafePaths.isRegularFile(f) else { NSSound.beep(); continue }
                    pieces.append(.inPlace(rel)); continue
                }
                // Only a regular file's bytes are copied (not a folder named x.png, not
                // a pipe; a symbolic link's target is read, the link isn't copied).
                let name: String
                do {
                    name = try store().copy(from: f, name: f.lastPathComponent)
                } catch ImageStore.Failure.notRegularFile {
                    NSSound.beep(); continue
                } catch let failure as ImageStore.Failure {
                    throw Self.imageStoreError(failure)
                }
                pieces.append(.copied(name))
            }
            if let bitmap {
                guard let png = NSBitmapImageRep(data: bitmap)?.representation(using: .png, properties: [:]) else { NSSound.beep(); return }
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyyMMdd-HHmmss"
                let name: String
                do {
                    name = try store().write(png, name: "image-\(f.string(from: Date())).png")
                } catch let failure as ImageStore.Failure {
                    throw Self.imageStoreError(failure)
                }
                pieces.append(.copied(name))
            }
        } catch {
            showError(error)
            if pieces.isEmpty { return }
        }
        guard !pieces.isEmpty else { return }
        // Just before inserting: every copied image's link must still lead to
        // the file written (ImageStore.link). If the folder or "images" was
        // swapped, nothing is inserted and the user is told.
        let paths: [String]
        do {
            paths = try pieces.map { piece in
                switch piece {
                case .inPlace(let rel): return rel
                case .copied(let name): return try store().link(for: name)
                }
            }
        } catch {
            showError(Self.imageStoreError(.destinationChanged))
            return
        }
        let len = (textView.string as NSString).length
        let r = NSRange(location: min(range.location, len), length: min(range.length, len - min(range.location, len)))
        let s = MarkdownPaste.imageLinks(paths)
        apply(TextEdit(range: r, replacement: s, selection: NSRange(location: r.location + (s as NSString).length, length: 0)),
              actionName: String(localized: "Insert Image"))
    }

    /// What the user is told when ImageStore refuses.
    static func imageStoreError(_ failure: ImageStore.Failure) -> NSError {
        let text: String, code: Int
        switch failure {
        case .outside:
            // An "images" that is a link out of the document's folder is refused.
            text = String(localized: "The “images” folder next to this document points outside its folder, so pasted images aren’t saved there.")
            code = 3
        case .destinationChanged:
            text = String(localized: "The “images” folder next to this document changed while the images were copied, so no links were inserted.")
            code = 4
        case .imagesIsLink:
            // On macOS 15 (no kernel-kept beneath lookups) only a real "images" folder is used.
            text = String(localized: "The “images” folder next to this document is a symbolic link, and on this version of macOS pasted images are only saved in a real folder. Replace the link with a folder.")
            code = 8
        case .otherVolume:
            text = String(localized: "The “images” folder next to this document is on a different volume from the document, so pasted images can’t be saved there. Use an “images” folder on the same volume.")
            code = 7
        case .notRegularFile, .badName:
            text = String(localized: "The image couldn’t be copied.")
            code = 6
        }
        return NSError(domain: "Cedric", code: code, userInfo: [NSLocalizedDescriptionKey: text])
    }

    /// Format › Markdown › Insert Image… (the Context Bar's Image button):
    /// image files picked in an open panel go through `insertImages`, the
    /// paste and drop path (same images/ folder, naming, no overwrite,
    /// links, one undo step; an untitled tab is asked to save first).
    /// Cancel changes nothing.
    func insertImageFiles() {
        guard markdownEditable, textView.multiCarets == nil, let window else { NSSound.beep(); return }
        ImageFilePicker.pick(for: window) { [weak self] urls in
            guard let self, let urls else { return }
            // What a paste takes: existing files with an image extension.
            let images = urls.filter { MarkdownPaste.isImageFile($0) && FileManager.default.fileExists(atPath: $0.path) }
            guard !images.isEmpty else { NSSound.beep(); return }
            guard self.markdownEditable else { NSSound.beep(); return }
            self.insertImages(images, bitmap: nil, at: self.textView.selectedRange())
        }
    }

    /// An untitled tab has no folder for the image: say so, and offer Save As.
    private func askToSaveForImages(_ files: [URL], bitmap: Data?, at range: NSRange) {
        guard let window else { NSSound.beep(); return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save this document first")
        alert.informativeText = String(localized: "Images are copied into an “images” folder next to the document, so it needs a folder. Nothing was inserted.")
        alert.addButton(withTitle: String(localized: "Save As…"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.saveAs(), self.doc.fileURL != nil else { return }
                self.insertImages(files, bitmap: bitmap, at: range)
            }
        }
    }
}

/// The open panel behind Insert Image…: image files only (the extensions
/// paste and drop take), one or several. Checks never show it: they set
/// `injected` (the URLs a user would pick, nil for Cancel).
@MainActor
enum ImageFilePicker {
    static let dryRun = DevEnvironment.values["CEDRIC_CHECK"] != nil
    static var injected: (() -> [URL]?)?
    /// Panels asked for (shown or, in checks, answered by `injected`).
    static var asks = 0

    static var contentTypes: [UTType] {
        MarkdownPaste.imageExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    /// `done` gets the picked files, or nil on Cancel; on the next turn of
    /// the run loop, after the panel's sheet has gone (a save-first sheet
    /// may follow).
    static func pick(for window: NSWindow, done: @escaping ([URL]?) -> Void) {
        asks += 1
        if dryRun {
            let r = injected?()
            DispatchQueue.main.async { done(r) }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = contentTypes
        panel.prompt = String(localized: "Insert")
        panel.message = String(localized: "Images are copied into the “images” folder next to the document.")
        panel.beginSheetModal(for: window) { response in
            let urls = response == .OK ? panel.urls : nil
            DispatchQueue.main.async { done(urls) }
        }
    }
}
