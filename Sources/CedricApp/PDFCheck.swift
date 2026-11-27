import AppKit
import CedricCore
import PDFKit

/// In-process check of PDF tabs (Scripts/pdf-check.sh). Makes its own
/// PDFs with Core Graphics (a 5-page one, an encrypted one, a damaged
/// file, a PDF with no extension), then drives the app with key
/// equivalents and menu actions as the other DevChecks do.
///
///   CEDRIC_CHECK=pdf          everything below; ends by saving the session
///                             (two PDF tabs, one on page 3 at 150%)
///   CEDRIC_CHECK=pdfrestore   after a relaunch with that session: pages,
///                             zoom, and the unselected tab not loaded yet
///   CEDRIC_PDF_DIR=/dir       where the PDFs go (both runs use the same)
@MainActor
extension DevChecks {
    static func pdfCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "pdf": pdf(app)
        case "pdfrestore": pdfRestore(app)
        case "pdfoverlay": pdfOverlayCheck(app)
        default: return false
        }
        return true
    }

    static var pdfDir: URL {
        DevEnvironment.values["CEDRIC_PDF_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? dir
    }

    /// A PDF of `pages` pages, each with "Page N" and a needle word, drawn
    /// as real text (so PDFKit can search and copy it).
    @discardableResult
    static func makePDF(_ url: URL, pages: Int, password: String? = nil) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        var info: [CFString: Any] = [kCGPDFContextTitle: "Cedric check"]
        if let password {
            info[kCGPDFContextUserPassword] = password
            info[kCGPDFContextOwnerPassword] = password + "-owner"
        }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { return false }
        let saved = NSGraphicsContext.current
        for p in 1...pages {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont(name: "Helvetica", size: 22) ?? NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
            ("Page \(p) of the owl manual" as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: attrs)
            ("Find the needle on this page." as NSString).draw(at: NSPoint(x: 72, y: 660), withAttributes: attrs)
            ("Line \(p * 10) says hoot." as NSString).draw(at: NSPoint(x: 72, y: 400), withAttributes: attrs)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        NSGraphicsContext.current = saved
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Waits (polling) until `cond` holds, then goes on; a FAIL if it never does.
    static func until(_ what: String, timeout: Double = 8, _ cond: @escaping @MainActor () -> Bool) -> (@escaping () -> Void) -> Void {
        { next in
            let start = Date()
            @MainActor func poll() {
                if cond() { next(); return }
                if Date().timeIntervalSince(start) > timeout { expect(false, what, "timed out"); next(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { poll() } }
            }
            poll()
        }
    }

    /// Whether a menu item would be enabled for the front window, found and
    /// validated along its responder chain as AppKit does for the key window.
    static func enabled(_ item: NSMenuItem) -> Bool {
        guard let action = item.action else { return false }
        let w = frontWindow
        var r: NSResponder? = w?.firstResponder
        var target: AnyObject?
        while let cur = r {
            if cur.responds(to: action) { target = cur; break }
            r = cur.nextResponder
        }
        if target == nil, let d = w?.delegate as? NSObject, d.responds(to: action) { target = d }
        if target == nil, let c = w?.windowController, c.responds(to: action) { target = c }
        if target == nil, let d = NSApp.delegate as? NSObject, d.responds(to: action) { target = d }
        guard let target else { return false }
        if let v = target as? NSMenuItemValidation { return v.validateMenuItem(item) }
        if let v = target as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) }
        return true
    }

    static func modified(_ url: URL) -> Date? { (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate }

    static func pdf(_ app: AppDelegate) {
        let dir = pdfDir
        let manual = dir.appendingPathComponent("owl manual.pdf")
        let second = dir.appendingPathComponent("second.pdf")
        let locked = dir.appendingPathComponent("locked.pdf")
        let noExt = dir.appendingPathComponent("download")
        let broken = dir.appendingPathComponent("broken.pdf")
        let notes = dir.appendingPathComponent("notes.txt")
        expect(makePDF(manual, pages: 5) && makePDF(second, pages: 3) && makePDF(locked, pages: 2, password: "hoot")
               && makePDF(noExt, pages: 2), "made the test PDFs")
        try? Data("this is not a PDF at all\n\u{0}\u{1}".utf8).write(to: broken)
        try? "plain notes\n".write(to: notes, atomically: true, encoding: .utf8)
        let manualBytes = try? Data(contentsOf: manual)
        let manualMod = modified(manual)
        var tab: PDFTabController?
        var textTabs = 0
        var savedPasteboard: String?
        func status() -> String { tab?.statusBar.position.stringValue ?? "-" }
        func page() -> Int { tab?.currentPageIndex ?? -1 }
        func scale() -> CGFloat { tab?.pdfView?.scaleFactor ?? -1 }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                expect(DocumentKind.detect(url: manual) == .pdf && DocumentKind.detect(url: noExt) == .pdf
                       && DocumentKind.detect(url: notes) == .text, "PDFs are told apart by their first bytes")
                let blank = app.tabs.first
                let r = app.open(manual)
                tab = app.pdfTab(for: manual)
                expect(r == nil && tab != nil, "File › Open on a PDF makes a PDF tab, not a text tab")
                expect(app.tabs.allSatisfy { $0.doc.fileURL?.standardizedFileURL != manual.standardizedFileURL }, "the PDF isn't decoded as text")
                expect(blank == nil || !app.tabs.contains { $0 === blank }, "the empty untitled tab it opened over is replaced")
                tab?.window?.setContentSize(NSSize(width: 1200, height: 720))
                tab?.window?.makeKeyAndOrderFront(nil)
                expect(tab?.pdfDocument?.pageCount == 5, "page count", "\(tab?.pdfDocument?.pageCount ?? -1)")
                expect(app.currentPDFTab === tab && app.currentTab == nil, "it is the current tab; no text tab is")
            },
            until("the page fits the window (not 10%)") { scale() > 0.8 },
            { next in
                // Links out of a PDF (security review 0.2.1): never opened
                // by PDFKit in one click. Web links ask with the whole URL,
                // files are only revealed, other schemes are ignored.
                guard let tab, let v = tab.pdfView else { expect(false, "pdf links: a PDF view"); next(); return }
                PreviewLinkLog.revealed = []
                PreviewLinkLog.opened = []
                let tabsBefore = app.tabs.count
                expect(v.delegate is PDFLinkDelegate, "the PDF view has Owlink's link delegate (not PDFKit's open-anything default)")
                v.delegate?.pdfViewWillClick?(onLink: v, with: URL(string: "smb://attacker.invalid/share")!)
                expect(tab.lastLinkAction == .ignore("smb"), "pdf: an smb: link is ignored", "\(String(describing: tab.lastLinkAction))")
                v.perform(PDFActionURL(url: URL(string: "x-apple.systempreferences:com.apple.Security")!))
                expect(tab.lastLinkAction == .ignore("x-apple.systempreferences"), "pdf: other schemes are ignored",
                       "\(String(describing: tab.lastLinkAction))")
                v.perform(PDFActionURL(url: URL(string: "cedric-doc://doc/etc/hosts")!))
                expect(tab.lastLinkAction == .ignore("cedric-doc"), "pdf: a cedric-doc: link is ignored")
                v.perform(PDFActionRemoteGoTo(pageIndex: 0, at: .zero, fileURL: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")))
                expect(PreviewLinkLog.revealed.last?.lastPathComponent == "Terminal.app", "pdf: a link to an app is revealed in Finder, not launched")
                v.delegate?.pdfViewWillClick?(onLink: v, with: notes)
                expect(PreviewLinkLog.revealed.last?.lastPathComponent == "notes.txt" && app.tabs.count == tabsBefore,
                       "pdf: a file: link, even a text file, is only revealed")
                expect(PreviewLinkLog.opened.isEmpty, "pdf: nothing opened so far")
                guard let w = tab.window, w.isVisible, w.attachedSheet == nil else {
                    print("check: note: pdf web-link prompt not checked (window not visible)"); next(); return
                }
                v.perform(PDFActionURL(url: URL(string: "https://example.com/a?b=1")!))
                @MainActor func allViews(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(allViews) }
                let sheet = w.attachedSheet
                let shown = sheet.flatMap { s in s.contentView.flatMap { allViews($0) }?
                    .compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: " ") }
                expect(shown?.contains("https://example.com/a?b=1") == true, "pdf: a web link asks first, showing the whole URL", shown ?? "no sheet")
                if let sheet { w.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    MainActor.assumeIsolated {
                        expect(PreviewLinkLog.opened.isEmpty && w.attachedSheet == nil, "pdf: Cancel opens nothing")
                        next()
                    }
                }
            },
            sync {
                expect(status() == "Page 1 of 5", "status bar: page N of M", status())
                expect(tab?.statusBar.zoom.stringValue == "\(Int((scale() * 100).rounded()))%", "status bar: zoom", tab?.statusBar.zoom.stringValue ?? "-")
                expect(tab?.statusBar.languageButton.isHidden == true && tab?.statusBar.encodingButton.isHidden == true,
                       "no language or encoding menus on a PDF")
                expect(tab?.pdfView?.displayMode == .singlePageContinuous, "continuous scroll")
                expect(tab?.window?.title == "owl manual.pdf" && tab?.window?.isDocumentEdited == false, "titled by its file, never edited")
                // The owl stays out of PDF tabs.
                var owlViews = 0
                @MainActor func walk(_ v: NSView) { if String(describing: Swift.type(of: v)).contains("Owl") { owlViews += 1 }; v.subviews.forEach(walk) }
                tab?.window?.contentView.map(walk)
                expect(owlViews == 0, "no owl in a PDF tab", "\(owlViews)")
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            sync {
                // Menus: what applies is on, editing and saving are off.
                let on: [(String, String, NSEvent.ModifierFlags)] = [
                    ("Copy", "c", .command), ("Select All", "a", .command), ("Find…", "f", .command), ("Find Next", "g", .command),
                    ("Go to Page…", "l", .command), ("Zoom In", "=", .command), ("Zoom Out", "-", .command), ("Actual Size", "0", .command),
                    ("Zoom to Fit", "9", .command), ("Show Page Thumbnails", "b", [.command, .option]), ("Print…", "p", .command),
                    ("Close Window", "w", [.command, .shift]),
                ]
                let off: [(String, String, NSEvent.ModifierFlags)] = [
                    ("Save", "s", .command), ("Save As…", "s", [.command, .shift]), ("Cut", "x", .command), ("Paste", "v", .command),
                    ("Undo", "z", .command), ("Redo", "z", [.command, .shift]), ("Find and Replace…", "f", [.command, .option]),
                    ("Duplicate Line", "d", [.command, .shift]), ("Comment Selection", "/", .command), ("Sort Lines A→Z", "s", [.control, .command]),
                    ("Bookmark Line", f2, .command), ("Show Preview", "p", [.command, .option]), ("Mark All", "m", [.control, .command]),
                    ("Find in Files…", "f", [.command, .shift]), ("Indent", "]", .command), ("Delete Line", "k", [.command, .shift]), ("Check Document Now", ";", .command),
                ]
                for (title, k, m) in on {
                    let it = menuItem(k, m)
                    let ok = it.map(enabled) ?? false // (validation sets "Go to Page…")
                    // A view toggle says Show or Hide (UX review #7).
                    let same = it?.title == title || (title.hasPrefix("Show ") && it?.title == "Hide " + title.dropFirst(5))
                    expect(ok && same, "enabled on a PDF tab: \(title)", it?.title ?? "no item")
                }
                for (title, k, m) in off {
                    let it = menuItem(k, m)
                    expect(it != nil && !(it.map(enabled) ?? true), "disabled on a PDF tab: \(title)", it?.title ?? "no item")
                }
                for (action, name) in [(#selector(AppDelegate.revertToSaved(_:)), "Revert to Saved"),
                                       (#selector(AppDelegate.pickLanguageMenu(_:)), "Format › Language"),
                                       (#selector(AppDelegate.pickEncodingMenu(_:)), "Format › Encoding"),
                                       (#selector(AppDelegate.indentUsingSpacesMenu(_:)), "Text › Indentation"),
                                       (#selector(AppDelegate.followFileMenu(_:)), "Follow File")] {
                    let it = menuItem(action: action)
                    expect(it != nil && !(it.map(enabled) ?? true), "disabled on a PDF tab: \(name)")
                }
                let oat = menuItem(action: #selector(PDFTabController.openAsText(_:)))
                expect(oat.map(enabled) == true, "enabled on a PDF tab: Open as Text")
            },
            // Find (⌘F): Cedric's find bar, searched by PDFKit.
            sync {
                key("f", .command)
                expect(tab?.isFindBarOpen == true, "⌘F shows the find bar")
                expect(tab?.findBar.regexBox.isHidden == true && tab?.findBar.wordBox.isHidden == true, "no regex / whole word for a PDF")
                tab?.findBar.findField.stringValue = "needle"
                tab?.findBar.onChange?()
            },
            until("the search finishes") { tab?.findInProgress == false },
            sync {
                expect(tab?.matches.count == 5, "finds the word on every page", "\(tab?.matches.count ?? -1)")
                expect(tab?.findBar.status.stringValue == "5 matches", "match count in the bar", tab?.findBar.status.stringValue ?? "-")
                expect(tab?.pdfView?.currentSelection?.string?.lowercased() == "needle", "the first match is selected")
                expect(page() == 0, "on page 1", "\(page())")
                key("g", .command)
            },
            sync {
                expect(page() == 1 && tab?.pdfView?.currentSelection?.string == "needle", "⌘G: the next match, on page 2", "\(page())")
                key("g", .command); key("g", .command); key("g", .command)
            },
            sync {
                expect(page() == 4, "⌘G to the last page", "\(page())")
                key("g", .command)
            },
            sync {
                expect(page() == 0, "⌘G wraps to the first match", "\(page())")
                key("g", [.command, .shift])
            },
            sync {
                expect(page() == 4, "⇧⌘G wraps back to the last", "\(page())")
                tab?.findBar.caseBox.state = .on
                tab?.findBar.findField.stringValue = "NEEDLE"
                tab?.findBar.onChange?()
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            until("the case-sensitive search finishes") { tab?.findInProgress == false },
            sync {
                expect(tab?.matches.count == 0 && tab?.findBar.status.stringValue == "0 matches", "Match Case", tab?.findBar.status.stringValue ?? "-")
                tab?.findBar.caseBox.state = .off
                tab?.findBar.findField.stringValue = "hoot"
                tab?.findBar.onChange?()
            },
            until("the third search finishes") { tab?.findInProgress == false },
            sync {
                expect(tab?.matches.count == 5, "searching again counts again", "\(tab?.matches.count ?? -1)")
                tab?.hideFindBar()
                expect(tab?.isFindBarOpen == false && tab?.window?.firstResponder === tab?.pdfView, "Done hides the bar, back to the page")
            },
            // Select and copy (⌘A, ⌘C go to PDFView).
            sync {
                savedPasteboard = NSPasteboard.general.string(forType: .string)
                NSPasteboard.general.clearContents()
                key("a", .command)
                key("c", .command)
            },
            sync {
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                expect(copied.contains("Page 1 of the owl manual") && copied.contains("Page 5 of the owl manual"), "⌘A ⌘C copies the PDF's text",
                       String(copied.prefix(80)))
                NSPasteboard.general.clearContents()
                if let savedPasteboard { NSPasteboard.general.setString(savedPasteboard, forType: .string) }
                tab?.pdfView?.clearSelection()
            },
            // Go to Page (⌘L, Go to Line's shortcut).
            sync { key("l", .command) },
            { next in
                guard let sheet = tab?.window?.attachedSheet, let f = field(in: sheet) else { expect(false, "⌘L asks for a page"); next(); return }
                expect(true, "⌘L asks for a page")
                f.stringValue = "4"
                pressReturn(in: sheet)
                next()
            },
            sync {
                expect(page() == 3 && status() == "Page 4 of 5", "Go to Page 4", status())
                let gl = menuItem("l", .command)
                _ = gl.map(enabled)
                expect(gl?.title == "Go to Page…", "the menu says Go to Page… on a PDF tab", gl?.title ?? "-")
            },
            // Zoom: ⌘= ⌘- ⌘0 ⌘9, like the editor's.
            sync {
                key("0", .command)
                expect(abs(scale() - 1) < 0.001 && tab?.statusBar.zoom.stringValue == "100%", "⌘0: actual size", "\(scale())")
                key("=", .command)
                expect(abs(scale() - 1.25) < 0.001 && tab?.statusBar.zoom.stringValue == "125%", "⌘=: zoom in", "\(scale())")
                key("-", .command)
                key("-", .command)
                expect(abs(scale() - 0.8) < 0.001 && tab?.statusBar.zoom.stringValue == "80%", "⌘-: zoom out", "\(scale())")
                expect(page() == 3, "zooming keeps the page", "\(page())")
                key("9", .command)
                expect(tab?.pdfView?.autoScales == true, "⌘9: fit again")
            },
            // Thumbnails sidebar.
            sync {
                key("b", [.command, .option])
                expect(tab?.thumbnails?.isHidden == false && (tab?.thumbnails?.frame.width ?? 0) > 60, "⌥⌘B shows the page thumbnails",
                       "\(tab?.thumbnails?.frame.width ?? -1)")
            },
            snapshot("pdf-thumbnails.png"),
            sync {
                key("b", [.command, .option])
                expect(tab?.thumbnails?.isHidden == true, "⌥⌘B hides them")
            },
            // Open as Text: a new untitled tab with the text, off the main thread.
            sync {
                textTabs = app.tabs.count
                guard let it = menuItem(action: #selector(PDFTabController.openAsText(_:))) else { expect(false, "Open as Text item"); return }
                NSApp.sendAction(it.action!, to: tab, from: it)
                expect(tab?.extracting == true, "Open as Text extracts in the background")
            },
        ]
        steps += steps3
        let steps4: [Step] = [
            until("Open as Text makes a tab") { app.tabs.count == textTabs + 1 && tab?.extracting == false },
            sync {
                let t = app.tabs.last
                let text = t?.text ?? ""
                expect(text.contains("Page 1 of the owl manual") && text.contains("Page 5 of the owl manual") && text.contains("Line 30 says hoot."),
                       "with the PDF's text", String(text.prefix(80)))
                expect(t?.doc.fileURL == nil && t?.doc.isDirty == true && t?.doc.displayName == "owl manual (text)",
                       "untitled and unsaved", t?.doc.displayName ?? "-")
                expect(t?.textView.isEditable == true, "and editable")
                expect(!text.contains("\r"), "LF line endings")
                t?.doc.markSaved()
                t?.window?.close()
                tab?.window?.makeKeyAndOrderFront(nil)
            },
            // The file is never written.
            sync {
                expect((try? Data(contentsOf: manual)) == manualBytes && modified(manual) == manualMod, "the PDF file is unchanged on disk")
            },
            // A PDF without the extension (magic bytes), the cedric URL with a page, -w.
            sync {
                app.open(noExt)
                let p = app.pdfTab(for: noExt)
                expect(p != nil && p?.pdfDocument?.pageCount == 2, "a PDF with no .pdf extension opens as a PDF")
                p?.window?.close()
                let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
                let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-wait.pdfcheck\(getpid())").path
                FileManager.default.createFile(atPath: marker, contents: nil)
                openURL(app, "cedric://open?path=\(enc(second.path))&line=3&wait=\(enc(marker))")
                let s = app.pdfTab(for: second)
                expect(s != nil, "cedric second.pdf opens a PDF tab")
                expect(s?.currentPageIndex == 2, "cedric second.pdf:3 opens it at page 3", "\(s?.currentPageIndex ?? -1)")
                expect(FileManager.default.fileExists(atPath: marker), "cedric -w waits while the PDF tab is open")
                s?.window?.performClose(nil)
                expect(!FileManager.default.fileExists(atPath: marker), "closing it releases cedric -w")
                expect(s?.window?.delegate == nil && s?.pdfView?.onZoom == nil, "a closed PDF tab's views are cut loose from it")
            },
            // Reopen Closed Tab brings a PDF tab back on its page.
            sync {
                expect(app.closedTabs.last?.pdf?.page == 2, "the closed PDF tab is remembered with its page", "\(String(describing: app.closedTabs.last?.pdf))")
                app.reopenClosedTab(nil)
            },
            until("Reopen Closed Tab: the PDF is back on page 3") { app.pdfTab(for: second)?.currentPageIndex == 2 },
            // Drops: a text file onto the PDF opens it; a PDF onto the text opens a PDF tab.
            sync {
                guard let v = app.pdfTab(for: second)?.pdfView else { expect(false, "second tab"); return }
                let pb = NSPasteboard(name: NSPasteboard.Name("cedric-check-pdfdrop-\(getpid())"))
                pb.clearContents()
                pb.writeObjects([notes as NSURL])
                let info = FakeDrag(pb, window: v.window, point: v.convert(NSPoint(x: 50, y: 50), to: nil))
                let op = v.draggingEntered(info)
                let ok = v.performDragOperation(info)
                expect(op == .copy && ok, "the PDF view takes a dropped file")
                let nt = app.tabs.first { $0.doc.fileURL?.standardizedFileURL == notes.standardizedFileURL }
                expect(nt?.text == "plain notes\n", "the dropped text file opens in a text tab")
                if let nt {
                    pb.clearContents()
                    pb.writeObjects([locked as NSURL])
                    _ = drop(pb, on: nt)
                }
                pb.releaseGlobally()
            },
            // The encrypted PDF (dropped above): a password sheet.
            until("the encrypted PDF asks for its password") { app.pdfTab(for: locked)?.passwordAlert != nil },
            { next in
                let l = app.pdfTab(for: locked)
                expect(l?.message?.contains("password") == true && l?.pdfView == nil, "locked: a message, no pages yet", l?.message ?? "-")
                guard let sheet = l?.window?.attachedSheet, let f = field(in: sheet) else { expect(false, "password field"); next(); return }
                f.stringValue = "wrong"
                pressReturn(in: sheet)
                next()
            },
        ]
        steps += steps4
        let steps5: [Step] = [
            until("a wrong password asks again") { app.pdfTab(for: locked)?.passwordAlert != nil },
            { next in
                let l = app.pdfTab(for: locked)
                expect(l?.pdfView == nil, "still locked after a wrong password")
                guard let sheet = l?.window?.attachedSheet, let f = field(in: sheet) else { expect(false, "password field again"); next(); return }
                f.stringValue = "hoot"
                pressReturn(in: sheet)
                next()
            },
            until("the right password opens it") { app.pdfTab(for: locked)?.pdfView != nil },
            sync {
                let l = app.pdfTab(for: locked)
                expect(l?.pdfDocument?.pageCount == 2 && l?.pdfDocument?.isLocked == false && l?.message == nil, "unlocked: 2 pages")
                l?.window?.close()
            },
            // A damaged .pdf: an alert, no tab, no crash.
            sync {
                tab?.window?.makeKeyAndOrderFront(nil)
                let before = app.pdfTabs.count + app.tabs.count
                app.open(broken)
                expect(app.pdfTabs.count + app.tabs.count == before, "a damaged PDF opens no tab (and isn't shown as text)")
            },
            { next in
                let sheet = tab?.window?.attachedSheet
                let text = (sheet?.contentView).map { v -> String in
                    var s = ""
                    @MainActor func walk(_ v: NSView) { if let f = v as? NSTextField { s += f.stringValue + " " }; v.subviews.forEach(walk) }
                    walk(v)
                    return s
                } ?? ""
                expect(text.contains("isn’t a PDF, or it is damaged"), "it says the file is damaged", text)
                if let sheet { pressReturn(in: sheet) }
                next()
            },
            // Theme changes reach the chrome; the pages stay white.
            { next in
                let before = tab?.pdfView?.backgroundColor
                // The run's theme (as CEDRIC_THEME sets it: never saved).
                let old = Settings.shared.themeOverride
                Settings.shared.themeOverride = Settings.shared.theme == .light ? .dark : .light
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let after = tab?.pdfView?.backgroundColor
                    expect(before != after && after == NSColor(hex: tab!.palette.gutterBackground), "the theme colours the PDF chrome",
                           "\(String(describing: before)) → \(String(describing: after))")
                    Settings.shared.themeOverride = old
                    NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next() }
                }
            },
            snapshot("pdf-tab.png"),
            // Leave a session for pdfrestore: a text tab, then this PDF on
            // page 3 at 150% (selected), and second.pdf on page 2.
            sync {
                let s = app.pdfTab(for: second)
                s?.goToPage(1)
                tab?.goToPage(2)
                tab?.setScale(1.5)
                tab?.window?.makeKeyAndOrderFront(nil)
                expect(tab?.sessionState == PDFTabState(page: 2, scale: 1.5, showsThumbnails: false), "session state: page and zoom",
                       "\(String(describing: tab?.sessionState))")
                app.saveSession()
                let saved = app.store.load()?.allTabs.compactMap(\.pdf) ?? []
                expect(saved.contains(PDFTabState(page: 2, scale: 1.5)) && saved.contains(PDFTabState(page: 1)),
                       "the session keeps both PDF tabs", "\(saved)")
            },
        ]
        steps += steps5
        run(steps)
    }

    /// After a relaunch with the session `pdf` saved.
    static func pdfRestore(_ app: AppDelegate) {
        let manual = pdfDir.appendingPathComponent("owl manual.pdf")
        let second = pdfDir.appendingPathComponent("second.pdf")
        let m = app.pdfTab(for: manual), s = app.pdfTab(for: second)
        expect(m != nil && s != nil, "both PDF tabs come back")
        expect(m?.isLoaded == true, "the selected PDF tab is loaded")
        expect(s?.isLoaded == false, "the other PDF tab isn't loaded until it is shown (launch speed)")
        run([
            until("the selected PDF is back on page 3") { m?.currentPageIndex == 2 },
            sync {
                expect(m?.currentPageIndex == 2, "the selected PDF tab is back on page 3", "\(m?.currentPageIndex ?? -1)")
                expect(s?.window?.tabGroup != nil && s?.window?.tabGroup === m?.window?.tabGroup, "in the same window's tab bar")
                expect(abs((m?.pdfView?.scaleFactor ?? 0) - 1.5) < 0.001 && m?.statusBar.zoom.stringValue == "150%", "at 150%",
                       "\(m?.pdfView?.scaleFactor ?? -1)")
                expect(m?.statusBar.position.stringValue == "Page 3 of 5", "status bar after restore", m?.statusBar.position.stringValue ?? "-")
                s?.window?.makeKeyAndOrderFront(nil)
                s?.ensureLoaded()
            },
            until("the other PDF loads on page 2 when shown") { s?.isLoaded == true && s?.currentPageIndex == 1 },
            sync {
                expect(s?.currentPageIndex == 1, "the other PDF tab, shown, is on page 2", "\(s?.currentPageIndex ?? -1)")
                expect(s?.pdfView?.autoScales == true, "fitted, as it was saved")
            },
        ])
    }
}

// MARK: - Render check (Scripts/render-check.sh)

@MainActor
enum PDFRenderCheck {
    /// A PDF tab in every theme, the whole window rendered (CALayer tree
    /// and cacheDisplay, as RenderDump.check does for text tabs): the page
    /// is white with ink where its text is, the chrome around it is the
    /// theme's, and the status bar shows the page.
    static func run(_ app: AppDelegate, out: String, report: (Bool, String, String) -> Void) {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-render-pdf-\(getpid())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("render.pdf")
        guard DevChecks.makePDF(url, pages: 3) else { report(false, "pdf/make", "couldn't write a PDF"); return }
        for c in TypingCheck.themes {
            TypingCheck.apply(c)
            guard let tab = app.openPDF(url), let window = tab.window, let v = tab.pdfView, let page = tab.pdfDocument?.page(at: 0) else {
                report(false, "\(c.name)/pdf", "no PDF tab")
                continue
            }
            window.setContentSize(NSSize(width: 900, height: 670))
            window.makeKeyAndOrderFront(nil)
            // Half size: the page with the theme's chrome round it.
            tab.setScale(0.5)
            tab.goToPage(0)
            TypingCheck.settle(0.4)
            window.displayIfNeeded()
            CATransaction.flush()
            let root = window.contentView!.superview ?? window.contentView!
            let p = tab.palette
            func onPage(_ r: NSRect) -> NSRect { v.convert(v.convert(r, from: page), to: root) }
            let pageRect = onPage(page.bounds(for: .mediaBox))
            // The first line of text, a blank stretch of the page, and the chrome left of it.
            let text = onPage(NSRect(x: 72, y: 698, width: 260, height: 26))
            let blank = onPage(NSRect(x: 250, y: 470, width: 100, height: 120))
            let pdfFrame = v.convert(v.bounds, to: root)
            let chrome = NSRect(x: pdfFrame.minX + 2, y: pageRect.midY - 30, width: max(0, pageRect.minX - pdfFrame.minX - 8), height: 60)
            let status = tab.statusBar.position.convert(tab.statusBar.position.bounds, to: root)
            report(tab.statusBar.position.stringValue == "Page 1 of 3", "\(c.name)/pdf/status", tab.statusBar.position.stringValue)
            for (how, rep) in [("layer", RenderDump.renderLayer(root)), ("cache", DevHooks.render(root, root.bounds))] {
                guard let rep else { report(false, "\(c.name)/pdf/\(how)", "no image"); continue }
                RenderDump.save(rep, "\(out)/\(c.name)-pdf-\(how).png")
                let notWhite = RenderDump.inkCount(rep, [blank], root: root, bg: .white, threshold: 1.25)
                report(notWhite == 0, "\(c.name)/pdf/\(how)/page-white", "pixels not white=\(notWhite)")
                let ink = RenderDump.inkCount(rep, [text], root: root, bg: .white)
                report(ink >= 30, "\(c.name)/pdf/\(how)/page-text", "ink=\(ink)")
                if chrome.width >= 4 {
                    let stray = RenderDump.inkCount(rep, [chrome], root: root, bg: NSColor(hex: p.gutterBackground), threshold: 1.25)
                    report(stray == 0, "\(c.name)/pdf/\(how)/chrome-theme", "pixels unlike the theme=\(stray)")
                } else {
                    report(false, "\(c.name)/pdf/\(how)/chrome-theme", "no chrome beside the page (\(chrome.width) px)")
                }
                let s = RenderDump.inkCount(rep, [status], root: root, bg: NSColor(hex: p.statusBar))
                report(s >= 10, "\(c.name)/pdf/\(how)/status-text", "ink=\(s)")
            }
            window.close()
            TypingCheck.settle(0.05)
        }
    }
}
