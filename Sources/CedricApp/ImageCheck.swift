import AppKit
import CedricCore
import ImageIO
import os
import UniformTypeIdentifiers

/// In-process check of image tabs and Office (Quick Look) tabs
/// (Scripts/image-check.sh). Makes its own images with ImageIO (PNG with
/// transparency, a JPEG turned by EXIF, an animated GIF, HEIC, a
/// 12000×12000 PNG), a .docx with NSAttributedString and an .xlsx zipped
/// from hand-written parts with /usr/bin/zip, then drives the app as the
/// other DevChecks do.
///
///   CEDRIC_CHECK=image          everything below; ends by saving the
///                               session (a PNG at 200%, a JPEG fitted,
///                               a .docx)
///   CEDRIC_CHECK=imagerestore   after a relaunch with that session
///   CEDRIC_IMAGE_DIR=/dir       where the files go (both runs use the same)
@MainActor
extension DevChecks {
    static func imageCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "image": images(app)
        case "imagerestore": imagesRestore(app)
        default: return false
        }
        return true
    }

    static var imageDir: URL {
        DevEnvironment.values["CEDRIC_IMAGE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? dir
    }

    /// Writes `frames` images of w×h (drawn by `draw`) as `type`.
    @discardableResult
    nonisolated static func makeImage(_ url: URL, _ type: UTType, width w: Int, height h: Int, frames: Int = 1, gray: Bool = false,
                                      properties: [CFString: Any] = [:], draw: (CGContext, Int) -> Void) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, frames, nil) else { return false }
        if frames > 1 {
            CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        }
        for f in 0..<frames {
            let space = gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!
            let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info) else { return false }
            draw(ctx, f)
            guard let img = ctx.makeImage() else { return false }
            var props = properties
            if frames > 1 { props[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: 0.05] }
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
        }
        return CGImageDestinationFinalize(dest)
    }

    /// Zips hand-written parts with /usr/bin/zip (as the unit tests do).
    nonisolated static func zipParts(_ out: URL, _ files: [String: String]) -> Bool {
        let src = out.deletingLastPathComponent().appendingPathComponent("parts-\(out.lastPathComponent)")
        try? FileManager.default.removeItem(at: src)
        for (path, text) in files {
            let u = src.appendingPathComponent(path)
            try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: u, atomically: true, encoding: .utf8)
        }
        let made = out.deletingLastPathComponent().appendingPathComponent("made-\(getpid()).zip")
        try? FileManager.default.removeItem(at: made)
        try? FileManager.default.removeItem(at: out)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = src
        p.arguments = ["-X", "-q", "-r", made.path] + files.keys.sorted { a, b in a.hasPrefix("[") != b.hasPrefix("[") ? a.hasPrefix("[") : a < b }
        p.standardOutput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: src)
        return (try? FileManager.default.moveItem(at: made, to: out)) != nil
    }

    static let xlsxParts: [String: String] = [
        "[Content_Types].xml": #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/></Types>"#,
        "_rels/.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
        "xl/workbook.xml": #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Owls" sheetId="1" r:id="rId1"/></sheets></workbook>"#,
        "xl/_rels/workbook.xml.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/></Relationships>"#,
        "xl/sharedStrings.xml": #"<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" count="3" uniqueCount="3"><si><t>Owl</t></si><si><t>Hoots</t></si><si><t>Barn, white</t></si></sst>"#,
        "xl/worksheets/sheet1.xml": #"<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>12.5</v></c></row><row r="3"><c r="A3" t="inlineStr"><is><t>Snowy</t></is></c><c r="B3"><f>B2*2</f><v>25</v></c></row></sheetData></worksheet>"#,
    ]
    static let xlsxCSV = "Owl,Hoots\n\"Barn, white\",12.5\nSnowy,25\n"

    static func pixel(_ rep: NSBitmapImageRep, _ p: NSPoint) -> NSColor? {
        rep.colorAt(x: Int(p.x * CGFloat(rep.pixelsWide) / rep.size.width), y: Int(p.y * CGFloat(rep.pixelsHigh) / rep.size.height))?.usingColorSpace(.sRGB)
    }

    static func images(_ app: AppDelegate) {
        let d = imageDir
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let png = d.appendingPathComponent("owl.png")         // 2400×1600, right half transparent
        let jpeg = d.appendingPathComponent("turned.jpg")     // 640×480 stored, EXIF 6: shown 480×640
        let gif = d.appendingPathComponent("blink.gif")       // 3 frames
        let heic = d.appendingPathComponent("photo.heic")
        let noExt = d.appendingPathComponent("download-image")
        let broken = d.appendingPathComponent("broken.png")
        let big = d.appendingPathComponent("huge.png")         // 12000×12000
        let notes = d.appendingPathComponent("notes.txt")
        let docx = d.appendingPathComponent("report.docx")
        let docNoExt = d.appendingPathComponent("download-doc")
        let xlsx = d.appendingPathComponent("owls.xlsx")
        let made = makeImage(png, .png, width: 2400, height: 1600) { ctx, _ in
            ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        } && makeImage(jpeg, .jpeg, width: 640, height: 480, properties: [kCGImagePropertyOrientation: 6]) { ctx, _ in
            ctx.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
        } && makeImage(gif, .gif, width: 64, height: 64, frames: 3) { ctx, f in
            ctx.setFillColor([CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                              CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)][f])
            ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        } && makeImage(noExt, .png, width: 32, height: 16) { ctx, _ in
            ctx.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 32, height: 16))
        }
        expect(made, "made the test images (PNG, JPEG, animated GIF, no-extension PNG)")
        let heicMade = makeImage(heic, .heic, width: 400, height: 300) { ctx, _ in
            ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.7, blue: 0.3, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
        }
        expect(heicMade, "made a HEIC with ImageIO")
        try? Data("not an image\n".utf8).write(to: broken)
        try? "plain notes\n".write(to: notes, atomically: true, encoding: .utf8)
        let para = NSAttributedString(string: "Hello from the owl.\nSecond paragraph, with a comma.\n")
        let docxData = try? para.data(from: NSRange(location: 0, length: para.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        expect((try? docxData?.write(to: docx)) != nil && (try? docxData?.write(to: docNoExt)) != nil, "made a .docx with NSAttributedString")
        expect(zipParts(xlsx, xlsxParts), "made an .xlsx with /usr/bin/zip")
        let originals = [png, jpeg, gif, heic, docx, xlsx].map { ($0, try? Data(contentsOf: $0), modified($0)) }
        // The 12000×12000 PNG takes a few seconds: made in the background meanwhile.
        nonisolated(unsafe) var bigMade: Bool?
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = makeImage(big, .png, width: 12000, height: 12000, gray: true) { ctx, _ in
                ctx.setFillColor(gray: 0.85, alpha: 1)
                ctx.fill(CGRect(x: 0, y: 0, width: 12000, height: 12000))
                ctx.setFillColor(gray: 0.2, alpha: 1)
                for i in stride(from: 0, to: 12000, by: 400) { ctx.fill(CGRect(x: i, y: 0, width: 100, height: 12000)) }
            }
            DispatchQueue.main.async { bigMade = ok }
        }

        var tab: ImageTabController?
        var savedPasteboard: [NSPasteboardItem] = []
        var opened: [(URL, URL)] = []
        AppDelegate.openWithOverride = { file, appURL in opened.append((file, appURL)) }
        func status() -> String { tab?.statusText ?? "-" }
        func zoom() -> String { tab?.statusBar.zoom.stringValue ?? "-" }
        func scale() -> Double { Double(tab?.scale ?? -1) }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                expect(DocumentKind.detect(url: png) == .image && DocumentKind.detect(url: noExt) == .image && DocumentKind.detect(url: gif) == .image
                       && DocumentKind.detect(url: notes) == .text && DocumentKind.detect(url: docNoExt) == .office,
                       "images and Office files are told apart by their first bytes")
                let blank = app.tabs.first
                let r = app.open(png)
                tab = app.imageTab(for: png)
                expect(r == nil && tab != nil, "File › Open on a PNG makes an image tab, not a text tab")
                expect(app.tabs.allSatisfy { $0.doc.fileURL?.standardizedFileURL != png.standardizedFileURL }, "the image isn't decoded as text")
                expect(blank == nil || !app.tabs.contains { $0 === blank }, "the empty untitled tab it opened over is replaced")
                tab?.window?.setContentSize(NSSize(width: 1200, height: 720))
                tab?.window?.makeKeyAndOrderFront(nil)
                expect(app.currentViewerTab === tab && app.currentTab == nil && app.currentPDFTab == nil, "it is the current tab; no text tab is")
            },
            until("the PNG is decoded") { tab?.info != nil },
            until("and fitted to the window") { (tab?.scale ?? 1) < 0.99 },
            sync {
                let size = ImageInfoText.fileSize(Int64((try? png.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0))
                expect(status() == "2400 × 1600 px · \(size) · PNG · sRGB", "status bar: pixel size, file size, format, colour space", status())
                let fit = ImageZoom.fitScale(imageWidth: 2400, imageHeight: 1600, viewWidth: Double(tab!.scrollView.contentSize.width),
                                             viewHeight: Double(tab!.scrollView.contentSize.height))
                expect(abs(scale() - fit) < 0.002, "fit to the window by default", "\(scale()) vs \(fit)")
                expect(zoom() == ImageZoom.percent(scale()), "status bar: zoom", zoom())
                expect(tab?.fitted == true, "fitted")
                expect(tab?.window?.title == "owl.png" && tab?.window?.isDocumentEdited == false, "titled by its file, never edited")
                expect(tab?.statusBar.languageButton.isHidden == true && tab?.statusBar.encodingButton.isHidden == true, "no language or encoding menus")
                var owlViews = 0
                @MainActor func walk(_ v: NSView) { if String(describing: Swift.type(of: v)).contains("Owl") { owlViews += 1 }; v.subviews.forEach(walk) }
                tab?.window?.contentView.map(walk)
                expect(owlViews == 0, "no owl in an image tab", "\(owlViews)")
            },
            // The checkerboard behind the transparent half; the red half opaque.
            sync {
                guard let c = tab?.canvas, let rep = c.bitmapImageRepForCachingDisplay(in: c.bounds) else { expect(false, "render the canvas"); return }
                c.cacheDisplay(in: c.bounds, to: rep)
                let red = pixel(rep, NSPoint(x: 600, y: 800))
                expect((red?.redComponent ?? 0) > 0.7 && (red?.greenComponent ?? 1) < 0.4 && (red?.blueComponent ?? 1) < 0.4, "the opaque half is the image's red", "\(String(describing: red))")
                // Two neighbouring checker squares (8 points on screen) differ.
                let sq = 8 / max(c.magnification, 0.001)
                let a = pixel(rep, NSPoint(x: 1800 + sq * 0.5, y: 800 + sq * 0.5)), b = pixel(rep, NSPoint(x: 1800 + sq * 1.5, y: 800 + sq * 0.5))
                let differ = abs((a?.brightnessComponent ?? 0) - (b?.brightnessComponent ?? 0)) > 0.03
                expect(differ, "a checkerboard shows through the transparent half",
                       "\(String(describing: a)) / \(String(describing: b))")
            },
            snapshot("image-png.png"),
        ]
        steps += steps1
        let steps2: [Step] = [
            // 0.2.1: the right-click menu, by a real right-click on the image.
            sync {
                guard let t = tab, let w = t.window else { expect(false, "image tab for the right-click"); return }
                var seen: NSMenu?
                let nc = NotificationCenter.default
                let token = nc.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                    guard let m = note.object as? NSMenu, m.items.contains(where: { $0.title == "Show Info" }) else { return }
                    seen = m
                    // Close it from inside its tracking loop.
                    RunLoop.current.perform(inModes: [.eventTracking, .default]) { m.cancelTracking() }
                }
                let p = t.canvas.convert(NSPoint(x: t.canvas.bounds.midX, y: t.canvas.bounds.midY), to: nil)
                if let e = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    w.sendEvent(e)
                }
                nc.removeObserver(token)
                if seen == nil {
                    print("check: note: the synthetic right-click opened no menu (window not key); asking the canvas for it")
                    seen = NSEvent.mouseEvent(with: .rightMouseDown, location: p, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1).flatMap { t.canvas.menu(for: $0) }
                }
                let titles = seen?.items.map(\.title).filter { !$0.isEmpty } ?? []
                // "Open in Default App" is retitled with the app's name when validated ("Open in Preview"), as in the File menu.
                expect(titles == ["Zoom In", "Zoom Out", "Actual Size", "Zoom to Fit", "Rotate Left", "Rotate Right", "Copy Image", "Copy Path",
                                  "Reveal in Finder", AppDelegate.openInTitle(png), "Show Info"], "right-click on the image: its menu", "\(titles)")
                @MainActor func run(_ title: String) {
                    guard let i = seen?.items.first(where: { $0.title == title }), let a = i.action else { expect(false, "context item \(title)"); return }
                    expect(t.validateMenuItem(i), "\(title) is enabled")
                    NSApp.sendAction(a, to: i.target, from: i)
                }
                run("Rotate Right")
                expect(t.canvas.rotation == 90 && t.canvas.frame.size == NSSize(width: 1600, height: 2400) && t.fitted,
                       "Rotate Right turns the view (fitted again)", "\(t.canvas.rotation) \(t.canvas.frame.size)")
                expect(t.statusText.hasPrefix("2400 × 1600 px"), "…the file's size is unchanged", t.statusText)
                run("Rotate Left")
                expect(t.canvas.rotation == 0 && t.canvas.frame.size == NSSize(width: 2400, height: 1600), "Rotate Left turns it back")
                let before = t.scale
                run("Zoom In")
                expect(t.scale > before + 0.001 && !t.fitted, "Zoom In from the context menu", "\(before) → \(t.scale)")
                run("Zoom to Fit")
                expect(t.fitted && abs(t.scale - before) < 0.002, "Zoom to Fit")
                run("Copy Path")
                expect(NSPasteboard.general.string(forType: .string) == png.path, "Copy Path", NSPasteboard.general.string(forType: .string) ?? "-")
                run("Show Info")
                let sheet = w.attachedSheet
                // Swift 6.1 (CI) doesn't infer the main actor for a local
                // function inside a closure: walk the views iteratively.
                var labels: [String] = []
                var stack: [NSView] = sheet?.contentView.map { [$0] } ?? []
                while let v = stack.popLast() {
                    if let f = v as? NSTextField { labels.append(f.stringValue) }
                    stack.append(contentsOf: v.subviews.reversed())
                }
                let text = labels.joined(separator: " | ")
                expect(sheet != nil && text.contains("2400 × 1600") && text.contains("PNG") && text.contains("sRGB"),
                       "Show Info: dimensions, format and colour space", text.replacingOccurrences(of: "\n", with: " / "))
                if let sheet { w.endSheet(sheet) }
                expect(seen?.items.contains { $0.action == #selector(ImageTabController.revealImageInFinder(_:)) && $0.target === t } == true
                       && seen?.items.contains { $0.action == #selector(ImageTabController.openInDefaultApp(_:)) && $0.target === t } == true,
                       "Reveal in Finder and Open in Default App act on this image (not run here)")
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            // Menus: what applies is on, editing and saving are off.
            sync {
                let on: [(String, String, NSEvent.ModifierFlags)] = [
                    ("Copy", "c", .command), ("Zoom In", "=", .command), ("Zoom Out", "-", .command), ("Actual Size", "0", .command),
                    ("Zoom to Fit", "9", .command), ("Print…", "p", .command), ("Close Window", "w", [.command, .shift]),
                ]
                let off: [(String, String, NSEvent.ModifierFlags)] = [
                    ("Save", "s", .command), ("Save As…", "s", [.command, .shift]), ("Cut", "x", .command), ("Paste", "v", .command),
                    ("Undo", "z", .command), ("Find…", "f", .command), ("Find and Replace…", "f", [.command, .option]), ("Go to Line…", "l", .command),
                    ("Duplicate Line", "d", [.command, .shift]), ("Comment Selection", "/", .command), ("Show Preview", "p", [.command, .option]),
                    ("Find in Files…", "f", [.command, .shift]), ("Indent", "]", .command), ("Select All", "a", .command), ("Check Document Now", ";", .command),
                ]
                for (title, k, m) in on {
                    let it = menuItem(k, m)
                    expect((it.map(enabled) ?? false) && it?.title == title, "enabled on an image tab: \(title)", it?.title ?? "no item")
                }
                for (title, k, m) in off {
                    let it = menuItem(k, m)
                    expect(it != nil && !(it.map(enabled) ?? true), "disabled on an image tab: \(title)", it?.title ?? "no item")
                }
                for (action, name) in [(#selector(AppDelegate.revertToSaved(_:)), "Revert to Saved"), (#selector(AppDelegate.pickLanguageMenu(_:)), "Format › Language"),
                                       (#selector(AppDelegate.pickEncodingMenu(_:)), "Format › Encoding"), (#selector(PDFTabController.openAsText(_:)), "Open as Text"),
                                       (#selector(PDFTabController.togglePDFThumbnails(_:)), "Show Page Thumbnails")] {
                    let it = menuItem(action: action)
                    expect(it != nil && !(it.map(enabled) ?? true), "disabled on an image tab: \(name)")
                }
                let ow = menuItem(action: #selector(ImageTabController.openInDefaultApp(_:)))
                let owOn = ow.map(enabled) ?? false
                let expected = AppDelegate.defaultApp(for: png).map { "Open in \(AppDelegate.appName($0))" } ?? "-"
                expect(owOn && ow?.title == expected && !(ow?.title.contains("Cedric") ?? true), "File › Open in <default app>", ow?.title ?? "-")
                print("check: note: the PNG's default app here: \(ow?.title ?? "-")")
                if let ow { NSApp.sendAction(ow.action!, to: tab, from: ow) }
                expect(opened.count == 1 && opened.first?.0 == png && opened.first?.1 != Bundle.main.bundleURL, "Open in … hands the file to that app",
                       "\(opened)")
            },
            // Zoom: ⌘0 ⌘= ⌘- ⌘9, like the PDF tab's.
            sync {
                key("0", .command)
                expect(abs(scale() - 1) < 0.001 && zoom() == "100%" && tab?.fitted == false, "⌘0: actual size", "\(scale())")
                key("=", .command)
                expect(abs(scale() - 1.25) < 0.001 && zoom() == "125%", "⌘=: zoom in", "\(scale())")
                key("-", .command)
                key("-", .command)
                expect(abs(scale() - 0.8) < 0.001 && zoom() == "80%", "⌘-: zoom out", "\(scale())")
                key("9", .command)
                expect(tab?.fitted == true && scale() < 0.8, "⌘9: fit again", "\(scale())")
                expect(tab?.scrollView.allowsMagnification == true, "pinch zooms (the scroll view magnifies)")
            },
            // Pan: at 200%, a scroll-wheel event moves the image.
            sync {
                tab?.setScale(2, center: NSPoint(x: 1200, y: 800))
                let before = tab?.sessionState
                if let sv = tab?.scrollView, let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -150, wheel2: -150, wheel3: 0),
                   let e = NSEvent(cgEvent: cg) {
                    sv.scrollWheel(with: e)
                }
                let after = tab?.sessionState
                expect(after?.scale == 2 && (after?.centerX != before?.centerX || after?.centerY != before?.centerY), "scrolling pans the image",
                       "\(String(describing: before)) → \(String(describing: after))")
            },
            // Copy: the image on the clipboard.
            sync {
                savedPasteboard = (NSPasteboard.general.pasteboardItems ?? []).map { item in
                    let copy = NSPasteboardItem()
                    for t in item.types { if let d = item.data(forType: t) { copy.setData(d, forType: t) } }
                    return copy
                }
                key("c", .command)
                let pb = NSPasteboard.general
                expect(pb.types?.contains(.png) == true, "⌘C puts the PNG on the clipboard", "\(pb.types ?? [])")
                let img = NSImage(pasteboard: pb)
                let rep = img?.representations.first
                expect(rep?.pixelsWide == 2400 && rep?.pixelsHigh == 1600, "the copied image is the whole image", "\(rep?.pixelsWide ?? -1)×\(rep?.pixelsHigh ?? -1)")
                let tiff = pb.data(forType: .tiff)
                expect(tiff.flatMap { NSBitmapImageRep(data: $0) }?.pixelsWide == 2400, "and TIFF on demand, for apps that paste TIFF")
                pb.clearContents()
                if !savedPasteboard.isEmpty { pb.writeObjects(savedPasteboard) }
            },
        ]
        steps += steps3
        let steps4: [Step] = [
            // Print: the image fitted to one page (to a PDF, without panels).
            sync {
                let pdf = dir.appendingPathComponent("image-print.pdf")
                let info = NSPrintInfo()
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = pdf
                guard let op = tab?.makePrintOperation(info) else { expect(false, "a print operation"); return }
                op.showsPrintPanel = false
                op.showsProgressPanel = false
                expect(op.run(), "printing the image succeeds")
                let doc = CGPDFDocument(pdf as CFURL)
                expect(doc?.numberOfPages == 1, "on one page", "\(doc?.numberOfPages ?? 0)")
                if let page = doc?.page(at: 1) {
                    let box = page.getBoxRect(.mediaBox)
                    expect(box.width > box.height, "landscape for a wide image", "\(box)")
                }
                let printItem = menuItem("p", .command)
                expect(printItem?.action == #selector(AppDelegate.printDocument(_:)), "⌘P is File › Print…")
            },
            // Theme changes reach the chrome.
            { next in
                let before = tab?.scrollView.contentView.backgroundColor
                let old = Settings.shared.themeOverride
                Settings.shared.themeOverride = Settings.shared.theme == .light ? .dark : .light
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    let after = tab?.scrollView.contentView.backgroundColor
                    expect(after == NSColor(hex: tab!.palette.gutterBackground) && after != before, "the theme colours the image tab's chrome",
                           "\(String(describing: after))")
                    Settings.shared.themeOverride = old
                    NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next() }
                }
            },
            // A JPEG turned by EXIF, HEIC, no extension.
            sync { app.open(jpeg) },
            until("the JPEG is decoded") { app.imageTab(for: jpeg)?.info != nil },
            sync {
                let j = app.imageTab(for: jpeg)
                expect(j?.statusText.hasPrefix("480 × 640 px") == true && j?.statusText.contains("JPEG") == true, "a JPEG, turned by its EXIF orientation",
                       j?.statusText ?? "-")
                expect(j?.canvas.image?.width == 480 && j?.canvas.image?.height == 640, "drawn turned", "\(j?.canvas.image?.width ?? -1)")
                if heicMade { app.open(heic) }
                app.open(noExt)
            },
            until("the HEIC and the no-extension PNG are decoded") { (!heicMade || app.imageTab(for: heic)?.info != nil) && app.imageTab(for: noExt)?.info != nil },
            sync {
                if heicMade {
                    let h = app.imageTab(for: heic)
                    expect(h?.statusText.hasPrefix("400 × 300 px") == true && h?.statusText.contains("HEIC") == true, "a HEIC", h?.statusText ?? "-")
                    h?.window?.close()
                }
                let n = app.imageTab(for: noExt)
                expect(n?.statusText.hasPrefix("32 × 16 px") == true && n?.statusText.contains("PNG") == true, "a PNG with no extension opens as an image",
                       n?.statusText ?? "-")
                expect(n?.scale == 1, "a small image isn't enlarged to fit", "\(n?.scale ?? -1)")
                n?.window?.close()
            },
            // An animated GIF plays; Pause stops it, Space starts it.
            sync { app.open(gif) },
            until("the GIF plays", timeout: 6) { (app.imageTab(for: gif)?.framesShown ?? 0) >= 4 },
            snapshot("image-gif.png"),
            { next in
                let g = app.imageTab(for: gif)
                expect(g?.statusText.contains("GIF") == true && g?.statusText.contains("3 frames") == true, "status: GIF, 3 frames", g?.statusText ?? "-")
                expect(g?.playing == true && g?.playButton.isHidden == false && g?.playButton.title == "Pause", "animated, with a Pause button")
                if let b = g?.playButton { click(b, at: NSPoint(x: b.bounds.midX, y: b.bounds.midY)) }
                let shown = g?.framesShown ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    expect(g?.playing == false && g?.framesShown == shown && g?.playButton.title == "Play", "Pause stops it", "\(shown) → \(g?.framesShown ?? -1)")
                    if let w = g?.window, let c = g?.canvas { w.makeFirstResponder(c); keyTo(w, " ", code: 49) }
                    expect(g?.playing == true, "Space plays it again")
                    g?.window?.close()
                    next()
                }
            },
        ]
        steps += steps4
        let steps5: [Step] = [
            // A damaged .png: an alert, no tab.
            sync {
                tab?.window?.makeKeyAndOrderFront(nil)
                let before = app.viewerTabs.count + app.tabs.count
                app.open(broken)
                expect(app.viewerTabs.count + app.tabs.count == before, "a damaged image opens no tab (and isn't shown as text)")
            },
            { next in
                let sheet = tab?.window?.attachedSheet
                var text = ""
                @MainActor func walk(_ v: NSView) { if let f = v as? NSTextField { text += f.stringValue + " " }; v.subviews.forEach(walk) }
                sheet?.contentView.map(walk)
                expect(text.contains("isn’t an image Owlink can show"), "it says the file is damaged", text)
                if let sheet { pressReturn(in: sheet) }
                next()
            },
            // cedric file.jpg -w, Reopen Closed Tab.
            sync {
                let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s }
                app.imageTab(for: jpeg)?.window?.close()
                let marker = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cedric-wait.imagecheck\(getpid())").path
                FileManager.default.createFile(atPath: marker, contents: nil)
                openURL(app, "cedric://open?path=\(enc(jpeg.path))&wait=\(enc(marker))")
                let j = app.imageTab(for: jpeg)
                expect(j != nil, "cedric photo.jpg opens an image tab")
                expect(FileManager.default.fileExists(atPath: marker), "cedric -w waits while the image tab is open")
                j?.window?.performClose(nil)
                expect(!FileManager.default.fileExists(atPath: marker), "closing it releases cedric -w")
                expect(app.closedTabs.last?.image != nil && app.closedTabs.last?.path == jpeg.path, "the closed image tab is remembered")
                expect(j?.window?.delegate == nil, "a closed image tab's window is cut loose from it")
                app.reopenClosedTab(nil)
                expect(app.imageTab(for: jpeg) != nil, "Reopen Closed Tab brings it back")
            },
            until("the reopened JPEG loads") { app.imageTab(for: jpeg)?.info != nil },
            // Drops: an image onto a text (not Markdown) tab opens an image
            // tab; a text file onto the image opens a text tab.
            sync {
                app.imageTab(for: jpeg)?.window?.close()
                let nt = app.open(notes)
                let pb = NSPasteboard(name: NSPasteboard.Name("cedric-check-imagedrop-\(getpid())"))
                pb.clearContents()
                pb.writeObjects([jpeg as NSURL])
                if let nt { _ = drop(pb, on: nt) }
                pb.releaseGlobally()
            },
            until("the image dropped on the text opens in an image tab") { app.imageTab(for: jpeg) != nil },
            sync {
                expect(app.tabs.first { $0.doc.fileURL?.standardizedFileURL == notes.standardizedFileURL }?.text == "plain notes\n",
                       "the text tab it was dropped on is unchanged")
                app.tabs.first { $0.doc.fileURL?.standardizedFileURL == notes.standardizedFileURL }?.window?.close()
                guard let sv = tab?.scrollView else { return }
                let pb = NSPasteboard(name: NSPasteboard.Name("cedric-check-imagedrop2-\(getpid())"))
                pb.clearContents()
                pb.writeObjects([notes as NSURL])
                let info = FakeDrag(pb, window: sv.window, point: sv.convert(NSPoint(x: 50, y: 50), to: nil))
                expect(sv.draggingEntered(info) == .copy && sv.performDragOperation(info), "the image view takes a dropped file")
                expect(app.tabs.contains { $0.doc.fileURL?.standardizedFileURL == notes.standardizedFileURL }, "the dropped text file opens in a text tab")
                pb.releaseGlobally()
                app.tabs.first { $0.doc.fileURL?.standardizedFileURL == notes.standardizedFileURL }?.window?.close()
            },
        ]
        steps += steps5
        let steps6: [Step] = [
            // Office: a .docx in a Quick Look tab, Open as Text; an .xlsx, Open Sheet as CSV.
            sync {
                let r = app.open(docx)
                let o = app.officeTab(for: docx)
                expect(r == nil && o != nil, "a .docx opens in a Quick Look tab")
                o?.window?.setContentSize(NSSize(width: 1200, height: 720))
                expect(o?.preview.map { String(describing: Swift.type(of: $0)) }?.contains("QLPreviewView") == true,
                       "with Quick Look's QLPreviewView (QuickLookUI loaded at run time)", o?.preview.map { "\(Swift.type(of: $0))" } ?? o?.message ?? "-")
                expect(o?.statusBar.position.stringValue.hasPrefix("Word document · ") == true, "status: Word document and size",
                       o?.statusBar.position.stringValue ?? "-")
                expect(app.currentViewerTab === o && app.currentTab == nil, "it is the current tab; no text tab is")
                for (title, k, m) in [("Save", "s", NSEvent.ModifierFlags.command), ("Find…", "f", .command), ("Go to Line…", "l", .command),
                                      ("Undo", "z", .command), ("Paste", "v", .command), ("Zoom In", "=", .command), ("Find in Files…", "f", [.command, .shift])] {
                    let it = menuItem(k, m)
                    expect(it != nil && !(it.map(enabled) ?? true), "disabled on a Quick Look tab: \(title)", it?.title ?? "no item")
                }
                let oat = menuItem(action: #selector(PDFTabController.openAsText(_:)))
                expect(oat.map(enabled) == true && oat?.title == "Open as Text", "Open as Text is on for a .docx", oat?.title ?? "-")
                let ow = menuItem(action: #selector(ImageTabController.openInDefaultApp(_:)))
                _ = ow.map(enabled)
                print("check: note: the .docx's default app here: \(ow?.title ?? "-")")
                var owl = 0
                @MainActor func walk(_ v: NSView) { if String(describing: Swift.type(of: v)).contains("Owl") { owl += 1 }; v.subviews.forEach(walk) }
                o?.window?.contentView.map(walk)
                expect(owl == 0, "no owl in a Quick Look tab")
            },
            { next in DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() } },
            snapshot("office-docx.png"),
            sync {
                let o = app.officeTab(for: docx)
                let oat = menuItem(action: #selector(PDFTabController.openAsText(_:)))
                if let oat, let o { NSApp.sendAction(oat.action!, to: o, from: oat) }
                expect(o?.extracting == true, "Open as Text reads it in the background")
            },
            until("Open as Text makes a tab with the document's text") { app.tabs.contains { $0.doc.displayName == "report (text)" } },
            sync {
                let t = app.tabs.first { $0.doc.displayName == "report (text)" }
                let text = t?.text ?? ""
                expect(text.contains("Hello from the owl.") && text.contains("Second paragraph, with a comma."), "with the .docx's text", String(text.prefix(80)))
                expect(t?.doc.fileURL == nil && t?.doc.isDirty == true, "untitled and unsaved")
                t?.doc.markSaved()
                t?.window?.close()
                app.open(docNoExt)
                expect(app.officeTab(for: docNoExt) != nil, "a .docx with no extension opens in a Quick Look tab (zip contents)")
                app.officeTab(for: docNoExt)?.window?.close()
                app.open(xlsx)
                let x = app.officeTab(for: xlsx)
                expect(x?.format == .spreadsheet && x?.statusBar.position.stringValue.hasPrefix("Excel spreadsheet") == true, "an .xlsx in a Quick Look tab")
                let oat = menuItem(action: #selector(PDFTabController.openAsText(_:)))
                expect(oat.map(enabled) == true && oat?.title == "Open Sheet as CSV", "the item is Open Sheet as CSV for a spreadsheet", oat?.title ?? "-")
                if let oat, let x { NSApp.sendAction(oat.action!, to: x, from: oat) }
            },
            until("Open Sheet as CSV makes a tab") { app.tabs.contains { $0.doc.displayName == "owls (Owls)" } },
            sync {
                let t = app.tabs.first { $0.doc.displayName == "owls (Owls)" }
                expect(t?.text == xlsxCSV, "the first sheet as CSV (shared, inline, number, formula's cached value)", t?.text.debugDescription ?? "-")
                expect(t?.doc.language.rawValue.lowercased().contains("csv") == true, "in a CSV tab", t?.doc.language.rawValue ?? "-")
                t?.doc.markSaved()
                t?.window?.close()
                app.officeTab(for: xlsx)?.window?.close()
                expect(app.closedTabs.last?.office != nil, "a closed Quick Look tab is remembered")
                app.reopenClosedTab(nil)
                expect(app.officeTab(for: xlsx) != nil, "and Reopen Closed Tab brings it back")
                app.officeTab(for: xlsx)?.window?.close()
            },
            // Never written.
            sync {
                for (u, data, mod) in originals {
                    expect((try? Data(contentsOf: u)) == data && modified(u) == mod, "\(u.lastPathComponent) is unchanged on disk")
                }
            },
        ]
        steps += steps6
        let steps7: [Step] = [
            // A 12000×12000 PNG: decoded off the main thread, downsampled,
            // while typing goes on in a text tab.
            until("the 12000×12000 PNG is made", timeout: 120) { bigMade != nil },
            measureBigImage(app, big: big, made: { bigMade == true }),
            // Leave a session for imagerestore: owl.png at 200% (selected),
            // turned.jpg fitted, report.docx.
            sync {
                app.imageTab(for: big)?.window?.close()
                app.open(docx)
                tab?.window?.makeKeyAndOrderFront(nil)
                tab?.setScale(2, center: NSPoint(x: 600, y: 400))
                let st = tab?.sessionState
                expect(st?.scale == 2 && abs((st?.centerX ?? 0) - 0.25) < 0.01 && abs((st?.centerY ?? 0) - 0.25) < 0.01,
                       "session state: zoom and place", "\(String(describing: st))")
                app.saveSession()
                let saved = app.store.load()?.allTabs ?? []
                expect(saved.contains { $0.image?.scale == 2 } && saved.contains { $0.path == jpeg.path && $0.image != nil && $0.image?.scale == nil }
                       && saved.contains { $0.path == docx.path && $0.office != nil }, "the session keeps the image and Office tabs",
                       "\(saved.map { "\($0.path ?? "-") \(String(describing: $0.image)) \(String(describing: $0.office))" })")
                AppDelegate.openWithOverride = nil
            },
        ]
        steps += steps7
        run(steps)
    }

    /// Opens the big image, then types in a text tab while it decodes;
    /// measures the open call and how long the main thread kept a key
    /// waiting. A background thread asks the main queue for a key press
    /// every 20 ms and times how long each waited (main-queue work isn't
    /// subject to the timer coalescing an inactive app gets), with App Nap
    /// held off for the measurement.
    static func measureBigImage(_ app: AppDelegate, big: URL, made: @escaping @MainActor () -> Bool) -> (@escaping () -> Void) -> Void {
        { next in
            guard made() else { expect(false, "made the 12000×12000 PNG"); next(); return }
            nonisolated(unsafe) let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "image check timing")
            let typing = app.makeTab(EditorDocument(untitledName: "Typing"), text: "")
            typing.window?.makeKeyAndOrderFront(nil)
            typing.window?.makeFirstResponder(typing.textView)
            let t0 = Date()
            app.open(big)
            let openMs = Date().timeIntervalSince(t0) * 1000
            let bigTab = app.imageTab(for: big)
            typing.window?.makeKeyAndOrderFront(nil)
            typing.window?.makeFirstResponder(typing.textView)
            let word = Array("owls hoot at night ")
            // The keys' waits and counts live on the main thread; only the
            // stop flag is read from the background thread, behind a lock.
            let probe = TypingProbe()
            let stop = OSAllocatedUnfairLock(initialState: false)
            let start = Date()
            nonisolated(unsafe) let goOn = next
            let finish = { @MainActor in
                ProcessInfo.processInfo.endActivity(activity)
                let decode = (bigTab?.info?.decodeSeconds ?? -1) * 1000
                let waits = probe.waits, typed = probe.typed
                let maxWait = waits.max() ?? -1
                let sorted = waits.sorted()
                let p95 = sorted.isEmpty ? -1 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                print(String(format: "check: note: 12000×12000 PNG: open() %.1f ms; decode %.0f ms in the background, done at %.0f ms; %d keys typed meanwhile: longest wait %.1f ms, p95 %.1f ms; loaded() %.1f ms on the main thread",
                             openMs, decode, probe.loadedAt ?? -1, typed, maxWait, p95, bigTab?.loadedMs ?? -1))
                expect(openMs < 250, "opening a 12000×12000 PNG returns at once (header only)", String(format: "%.1f ms", openMs))
                expect(bigTab?.loading == false && bigTab?.info != nil, "it decodes (in the background)")
                expect(maxWait < 100, "typing in another tab isn't held up while it decodes (no key waits 100 ms)", String(format: "longest %.1f ms", maxWait))
                let text = typing.text
                expect(text.count == typed && text.hasPrefix("owls hoot"), "every key typed meanwhile arrived", "\(text.count)/\(typed)")
                let w = bigTab?.info?.display?.width ?? 0
                expect(bigTab?.statusText.hasPrefix("12000 × 12000 px") == true && w > 0 && w <= ImageZoom.displayMaxPixelSize(width: 12000, height: 12000),
                       "decoded downsampled for display", "\(bigTab?.statusText ?? "-"), display \(w) px")
                typing.doc.markSaved()
                typing.window?.close()
                bigTab?.window?.makeKeyAndOrderFront(nil)
                let d0 = Date()
                bigTab?.window?.displayIfNeeded()
                print(String(format: "check: note: first display of the big image tab: %.1f ms", Date().timeIntervalSince(d0) * 1000))
                expect(bigTab?.fitted == true && (bigTab?.scale ?? 1) < 0.1, "fitted to the window", "\(bigTab?.scale ?? -1)")
                goOn()
            }
            Thread.detachNewThread {
                // Until the image is in and 40 keys are typed (at most 30 s).
                while !stop.withLock({ $0 }) {
                    let sent = Date()
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard !stop.withLock({ $0 }) else { return }
                            probe.waits.append(Date().timeIntervalSince(sent) * 1000)
                            if let w = typing.window {
                                let ch = word[probe.typed % word.count]
                                keyTo(w, String(ch), code: ch == " " ? 49 : 0)
                                probe.typed += 1
                            }
                            if probe.loadedAt == nil, bigTab?.loading == false { probe.loadedAt = Date().timeIntervalSince(start) * 1000 }
                            if probe.loadedAt != nil && probe.typed >= 40 || Date().timeIntervalSince(start) > 30 {
                                stop.withLock { $0 = true }
                                finish()
                            }
                        }
                    }
                    usleep(20_000)
                }
            }
        }
    }

    /// The big-image timing's main-thread state (measureBigImage).
    @MainActor final class TypingProbe {
        var waits: [Double] = []
        var typed = 0
        var loadedAt: Double?
    }

    /// After a relaunch with the session `image` saved.
    static func imagesRestore(_ app: AppDelegate) {
        let d = imageDir
        let png = d.appendingPathComponent("owl.png"), jpeg = d.appendingPathComponent("turned.jpg"), docx = d.appendingPathComponent("report.docx")
        let p = app.imageTab(for: png), j = app.imageTab(for: jpeg), o = app.officeTab(for: docx)
        expect(p != nil && j != nil && o != nil, "the image and Office tabs come back")
        expect(p?.isLoaded == true, "the selected image tab is loading")
        expect(j?.isLoaded == false && o?.isLoaded == false, "the others aren't loaded until shown (launch speed)")
        run([
            until("the selected image is decoded") { p?.info != nil },
            sync {
                expect(abs((p?.scale ?? 0) - 2) < 0.001 && p?.statusBar.zoom.stringValue == "200%", "back at 200%", "\(p?.scale ?? -1)")
                let st = p?.sessionState
                expect(abs((st?.centerX ?? 0) - 0.25) < 0.02 && abs((st?.centerY ?? 0) - 0.25) < 0.02, "scrolled to the same place", "\(String(describing: st))")
                expect(p?.statusText.hasPrefix("2400 × 1600 px") == true, "status after restore", p?.statusText ?? "-")
                expect(j?.window?.tabGroup != nil && j?.window?.tabGroup === p?.window?.tabGroup, "in the same window's tab bar")
                j?.window?.makeKeyAndOrderFront(nil)
                j?.ensureLoaded()
            },
            until("the other image loads when shown") { j?.info != nil },
            sync {
                expect(j?.fitted == true, "fitted, as it was saved")
                o?.window?.makeKeyAndOrderFront(nil)
                o?.ensureLoaded()
                expect(o?.preview != nil, "the Quick Look tab shows its preview once shown")
            },
        ])
    }
}
