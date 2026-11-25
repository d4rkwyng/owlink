import AppKit
import CedricCore
import PDFKit

/// The PDF reader controls (PDFOverlay), in the running app: every control,
/// the page field, ← / → and Page Up / Down, fit page, view-only rotation
/// (the file's bytes unchanged), the auto-hide (fade after the delay, back
/// on a mouse move or scroll, kept while hovered), Reduce Motion (no fade),
/// a narrow window, and snapshots shown and after the fade.
///
///   CEDRIC_CHECK=pdfoverlay   (Scripts/pdf-check.sh)
@MainActor
extension DevChecks {
    static func pdfOverlayCheck(_ app: AppDelegate) {
        let url = pdfDir.appendingPathComponent("reader.pdf")
        expect(makePDF(url, pages: 5), "made the test PDF")
        let bytes = try? Data(contentsOf: url)
        var tab: PDFTabController?
        var o: PDFOverlay? { tab?.overlay }
        func page() -> Int { tab?.currentPageIndex ?? -1 }
        func scale() -> CGFloat { tab?.pdfView?.scaleFactor ?? -1 }
        func press(_ c: PDFOverlay.Control) { if let b = o?.buttons[c] { DevChecks.press(b) } }
        func pageKey(_ code: Int, _ keyCode: UInt16) {
            guard let v = tab?.pdfView, let w = v.window,
                  let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: w.windowNumber, context: nil,
                                           characters: String(UnicodeScalar(UInt16(code))!), charactersIgnoringModifiers: String(UnicodeScalar(UInt16(code))!),
                                           isARepeat: false, keyCode: keyCode) else { return }
            v.keyDown(with: e)
        }
        func wait(_ s: Double) -> (@escaping () -> Void) -> Void { { next in DispatchQueue.main.asyncAfter(deadline: .now() + s) { next() } } }
        var steps: [Step] = []
        let steps1: [Step] = [
            sync {
                PDFOverlay.reduceMotionOverride = false
                app.open(url)
                tab = app.pdfTab(for: url)
                tab?.window?.setContentSize(NSSize(width: 1200, height: 720))
                tab?.window?.makeKeyAndOrderFront(nil)
                expect(tab != nil, "the PDF opens in a tab")
            },
            until("the reader controls are built after the first frame") { o != nil && scale() > 0.5 },
            sync {
                guard let o, let tab, let pages = tab.pdfView else { return }
                tab.window?.layoutIfNeeded()
                expect(o.shown && !o.isHidden && o.alphaValue > 0.99, "shown when the PDF opens")
                let pf = pages.frame
                expect(pf.contains(o.frame) && abs(o.frame.midX - pf.midX) <= 1 && o.frame.minY - pf.minY <= 20,
                       "a capsule at the bottom centre of the pages", "overlay \(o.frame) pages \(pf)")
                expect(o.layer?.masksToBounds == true && o.layer?.cornerRadius == PDFOverlay.height / 2, "rounded, clipped to its bounds")
                for c in PDFOverlay.Control.allCases {
                    let b = o.buttons[c]
                    expect(b?.isHidden == false && b?.image != nil && b?.toolTip?.isEmpty == false && b?.accessibilityLabel()?.isEmpty == false,
                           "control \(c.rawValue): shown, symbol, tooltip, VoiceOver label")
                }
                expect(o.pageField.stringValue == "1" && o.ofLabel.stringValue == "of 5", "page 1 of 5", "\(o.pageField.stringValue) \(o.ofLabel.stringValue)")
                expect(o.buttons[.previous]?.isEnabled == false && o.buttons[.next]?.isEnabled == true, "previous is off on the first page")
            },
            snapshot("pdfoverlay-shown-dark.png"),
            sync {
                press(.next)
                expect(page() == 1 && o?.pageField.stringValue == "2", "next page", "\(page())")
                press(.previous)
                expect(page() == 0, "previous page", "\(page())")
                pageKey(NSPageDownFunctionKey, 121)
                expect(page() == 1, "Page Down: next page", "\(page())")
                pageKey(NSRightArrowFunctionKey, 124)
                expect(page() == 2, "→: next page", "\(page())")
                pageKey(NSLeftArrowFunctionKey, 123)
                expect(page() == 1, "←: previous page", "\(page())")
                pageKey(NSPageUpFunctionKey, 116)
                expect(page() == 0, "Page Up: previous page", "\(page())")
                o?.pageField.stringValue = "4"
                if let f = o?.pageField { f.sendAction(f.action, to: f.target) }
                expect(page() == 3 && o?.pageField.stringValue == "4", "the page field: 4 and Return jumps to page 4", "\(page())")
                o?.pageField.stringValue = "99"
                if let f = o?.pageField { f.sendAction(f.action, to: f.target) }
                expect(page() == 3 && o?.pageField.stringValue == "4", "a page that doesn't exist: stays, field put back", o?.pageField.stringValue ?? "-")
                press(.next)
                expect(page() == 4 && o?.buttons[.next]?.isEnabled == false, "next is off on the last page")
            },
            sync {
                press(.actualSize)
                expect(abs(scale() - 1) < 0.01, "actual size", "\(scale())")
                press(.zoomIn)
                expect(abs(scale() - 1.25) < 0.01, "zoom in", "\(scale())")
                press(.zoomOut)
                expect(abs(scale() - 1) < 0.01, "zoom out", "\(scale())")
                press(.fitPage)
                if let v = tab?.pdfView, let p = v.currentPage {
                    let b = p.bounds(for: v.displayBox)
                    expect(b.height * scale() <= v.bounds.height && b.width * scale() <= v.bounds.width && b.height * scale() > v.bounds.height * 0.8,
                           "fit page: the whole page shows", "page \(b.size) × \(scale()) in \(v.bounds.size)")
                }
                press(.fitWidth)
                expect(tab?.pdfView?.autoScales == true, "fit width")
                press(.thumbnails)
                expect(tab?.thumbnails?.isHidden == false, "thumbnails sidebar on")
                tab?.window?.layoutIfNeeded()
                if let o, let pf = tab?.pdfView?.frame {
                    expect(abs(o.frame.midX - pf.midX) <= 1, "the capsule stays centred on the pages beside the sidebar", "\(o.frame) \(pf)")
                }
            },
        ]
        steps += steps1
        let steps2: [Step] = [
            snapshot("pdfoverlay-thumbnails-dark.png"),
            sync {
                press(.thumbnails)
                expect(tab?.thumbnails?.isHidden == true, "thumbnails sidebar off")
                press(.find)
                expect(tab?.isFindBarOpen == true, "find opens the find bar")
                tab?.hideFindBar()
                press(.rotateRight)
                expect(tab?.viewRotation == 90 && tab?.pdfView?.currentPage?.rotation == 90, "rotate right turns the view", "\(tab?.viewRotation ?? -1)")
                press(.rotateLeft); press(.rotateLeft)
                expect(tab?.viewRotation == 270, "rotate left", "\(tab?.viewRotation ?? -1)")
                press(.rotateRight)
                expect(tab?.viewRotation == 0, "and back", "\(tab?.viewRotation ?? -1)")
                expect((try? Data(contentsOf: url)) == bytes, "rotating never writes the file")
                let open = o?.buttons[.openInDefaultApp]
                expect(open?.target === o && open?.action != nil, "Open in Default App is wired (not pressed: it would launch another app)")
                expect(open?.accessibilityLabel() == String(localized: "Open in Default App") && open?.toolTip == String(localized: "Open the PDF in its default app"),
                       "it is labelled Open in Default App (tooltip and VoiceOver), not Preview")
                o?.noteActivity()
            },
            // Idle past the delay: it fades and stops taking clicks.
            wait(0.6),
            sync { expect(o?.shown == true, "still shown about 1 s after the last activity") },
            wait(1.8),
            sync { expect(o?.shown == false, "faded after about 2 s idle") },
            wait(0.6),
            sync {
                guard let o else { return }
                expect(o.isHidden && o.alphaValue < 0.01, "hidden once the fade is done", "hidden=\(o.isHidden) alpha=\(o.alphaValue)")
                let p = NSPoint(x: o.frame.midX, y: o.frame.midY)
                expect(o.hitTest(p) == nil, "hidden, it takes no clicks (the page gets them)")
            },
            snapshot("pdfoverlay-faded-dark.png"),
            sync {
                (tab?.pdfView?.superview as? PDFPagesView).map { pages in
                    if let e = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                  context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { pages.mouseMoved(with: e) }
                }
                expect(o?.shown == true && o?.isHidden == false, "a mouse move brings it back")
                o?.hide()
            },
            wait(0.6),
            sync {
                tab?.goToPage(1)
                expect(o?.shown == true, "a scroll brings it back")
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { o?.mouseEntered(with: e) }
            },
            wait(2.8),
            sync {
                expect(o?.shown == true, "it stays while the pointer is on it")
                if let e = NSEvent.mouseEvent(with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                              context: nil, eventNumber: 0, clickCount: 0, pressure: 0) { o?.mouseExited(with: e) }
            },
        ]
        steps += steps2
        let steps3: [Step] = [
            wait(2.6),
            sync {
                expect(o?.shown == false, "and fades once the pointer leaves")
                PDFOverlay.reduceMotionOverride = true
                o?.show()
                expect(o?.alphaValue == 1 && o?.isHidden == false, "Reduce Motion: shown at once, no fade in")
                o?.hide()
                expect(o?.alphaValue == 0 && o?.isHidden == true, "Reduce Motion: hidden at once, no fade out")
                o?.noteActivity()
                Settings.shared.themeOverride = .light
                NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
            },
            snapshot("pdfoverlay-shown-light.png"),
            sync {
                // A narrow window with the sidebar: the lower-priority groups give way; page stepping stays.
                tab?.togglePDFThumbnails(nil)
                tab?.window?.setContentSize(NSSize(width: 480, height: 500))
                tab?.window?.layoutIfNeeded()
                guard let o, let pf = tab?.pdfView?.frame else { return }
                expect(o.frame.width <= pf.width - 16 && pf.contains(o.frame), "narrow: the capsule fits inside the pages", "\(o.frame) in \(pf)")
                expect(o.buttons[.next]?.isHidden == false && o.buttons[.previous]?.isHidden == false && !o.pageField.isHidden,
                       "narrow: page stepping stays")
                expect(o.groupShown.contains(false), "narrow: some groups are dropped", "\(o.groupShown)")
                tab?.togglePDFThumbnails(nil)
            },
            snapshot("pdfoverlay-narrow-light.png"),
        ]
        steps += steps3
        run(steps, gap: 0.3)
    }
}
