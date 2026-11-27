import AppKit
import CedricCore
import CedricAI

/// Two owl checks (Scripts/owl-check.sh):
///
/// CEDRIC_OWL_CHECK_HISTORY=1, a saved text file holding `historyText`:
///   1. the rules offer the doubled word; the bubble is closed;
///   2. the owl's popover lists it under "Recent hints" as a button (role,
///      label, in the key view loop); a click shows it again in the bubble
///      with Fix it and the hint's range, without a new query;
///   3. the text is changed so the range is stale; Return on the focused
///      row shows its title and detail, no Fix it, no range.
///
/// CEDRIC_OWL_CHECK_CAP=1, a saved log over the auto-review cap (the fake
/// AI, automatic checks on, every AI wait 0.2 s):
///   1. it is capped but not in large mode; typing and pausing never asks
///      the AI (no request, no "thinking", no last check);
///   2. the popover shows the quiet note; Ask AI Now asks for confirmation
///      (Cancel is the default) and Cancel sends nothing;
///   3. Ask AI Now again, Ask Anyway: one check runs.
@MainActor
enum OwlHistoryCapCheck {
    static func check(_ ok: Bool, _ what: String) { OwlCheck.check(ok, what) }

    static let historyText = "Fix the the bug.\n"

    static func copyShot(_ path: String) {
        guard let dir = DevEnvironment.values["CEDRIC_OWL_CHECK_SHOTS"], !dir.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let dest = (dir as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        try? FileManager.default.removeItem(atPath: dest)
        try? FileManager.default.copyItem(atPath: path, toPath: dest)
    }

    static func shot(_ window: NSWindow?, _ path: String, then: @escaping @MainActor () -> Void) {
        guard let window else { check(false, "a window to snapshot for \(path)"); then(); return }
        OwlCheck.snapshot(window, path) { copyShot(path); then() }
    }

    /// A sheet's own background is drawn by the window server, so an
    /// offscreen render is its controls on nothing: drawn here over the
    /// window background colour in the sheet's appearance.
    static func shotSheet(_ sheet: NSWindow, _ path: String, then: @escaping @MainActor () -> Void) {
        guard let root = sheet.contentView?.superview ?? sheet.contentView,
              let rep = DevHooks.render(root, root.bounds) else { check(false, "rendered the sheet"); then(); return }
        let img = NSImage(size: root.bounds.size)
        img.lockFocus()
        sheet.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: root.bounds.size).fill()
        }
        rep.draw(in: NSRect(origin: .zero, size: root.bounds.size), from: .zero, operation: .sourceOver, fraction: 1,
                 respectFlipped: false, hints: nil)
        img.unlockFocus()
        if let tiff = img.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
            print("owlcheck: wrote \(path)")
            copyShot(path)
        }
        then()
    }

    static func openPopover(_ owl: OwlController, then: @escaping @MainActor (Bool) -> Void) {
        if owl.popoverShown { then(true); return }
        OwlCheck.click(owl.owl)
        AICheck.wait("the popover", timeout: 3, { owl.popoverShown }) { then($0) }
    }

    /// A real click on a row (mouse down/up through its window). A locked
    /// screen can swallow it in the popover's window; then the same events
    /// go to the row the hit test found (as `OwlCheck.click` does for
    /// buttons), and the fallback is logged.
    static func clickRow(_ row: OwlRecentHintRow, owl: OwlController) {
        let before = owl.replays
        OwlCheck.click(row)
        guard owl.replays == before, let w = row.window else { return }
        let p = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        let hit = w.contentView?.superview?.hitTest(p) ?? w.contentView?.hitTest(p)
        check(hit === row, "a click on the row's label hits the row (\(hit.map { String(describing: type(of: $0)) } ?? "nothing"))")
        print("owlcheck: (window didn't deliver the click; sending it to the row)")
        guard let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return }
        row.mouseDown(with: down)
        row.mouseUp(with: up)
    }

    /// Whether `row` is reached by Tab from the popover's first key view.
    static func inKeyLoop(_ row: NSView) -> Bool {
        guard let w = row.window, let start = w.contentView else { return false }
        var v: NSView? = start.nextValidKeyView
        var seen = Set<ObjectIdentifier>()
        while let x = v, seen.insert(ObjectIdentifier(x)).inserted {
            if x === row { return true }
            v = x.nextValidKeyView
        }
        return false
    }

    // MARK: History

    static func runHistory(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl else { OwlCheck.finish(out); return }
        let hub = OwlHub.shared
        check(tab.text == historyText, "opened the file (\(tab.text.debugDescription))")
        check(!tab.autoReviewCapped, "a small file is under the auto-review cap")
        let id = RulesHintProvider.duplicateWordID
        OwlRulesCheck.waitFor(id, in: tab) { bubble in
            guard bubble != nil, let shown = owl.presentedHint else { OwlCheck.finish(out); return }
            let title = shown.hint.title
            check(shown.documentRange != nil, "the first showing has a range")
            owl.hideBubble()
            check(!hub.coordinator.isEligible(shown.hint, documentID: tab.doc.id), "the hint is shown already (not eligible again)")
            let queries = hub.coordinator.queryCount
            openPopover(owl) { ok in
                check(ok, "the popover opened")
                let rows = owl.popoverRecentRows
                guard let row = rows.first(where: { ($0.accessibilityLabel() ?? "").contains(title) }) else {
                    check(false, "a recent-hint row for “\(title)” (\(rows.map { $0.label.stringValue }))"); OwlCheck.finish(out); return
                }
                check(row.accessibilityRole() == .button, "the row is a button for VoiceOver (\(String(describing: row.accessibilityRole())))")
                check(row.isAccessibilityElement(), "and an accessibility element")
                let spoken = row.accessibilityLabel() ?? ""
                check(spoken.contains(title) && spoken.contains(shown.hint.detail ?? "\u{0}"),
                      "its label has the time, title and detail (\(spoken))")
                check(row.label.font?.pointSize == 11 && row.label.preferredMaxLayoutWidth == 260,
                      "11 pt wrapping label, 260 pt wide, as before")
                check(row.label.stringValue.hasSuffix("  " + title), "it reads “time  title” (\(row.label.stringValue))")
                check(row.canBecomeKeyView && inKeyLoop(row), "Tab reaches it (in the popover's key view loop)")
                check(owl.popoverButtonsFit, "the popover's buttons still fit")
                shot(owl.popoverWindow, "\(out)/history-1-popover.png") {
                    clickRow(row, owl: owl)
                    AICheck.wait("the bubble again", timeout: 3, { owl.bubble != nil }) { ok in
                        check(ok && owl.presentedHint?.hint.id == id, "clicking the row showed the hint again")
                        check(!owl.popoverShown, "and closed the popover")
                        check(owl.presentedHint?.documentRange == shown.documentRange, "with its range (highlight, Show Me)")
                        let titles = owl.bubble?.buttons.map(\.title) ?? []
                        check(titles.contains(String(localized: "Fix it")), "and Fix it (\(titles))")
                        check(hub.coordinator.queryCount == queries, "without asking the rules again")
                        check(owl.replays == 1, "one replay")
                        shot(window, "\(out)/history-2-reopened.png") { stale(tab, owl: owl, id: id, title: title, detail: shown.hint.detail, out: out) }
                    }
                }
            }
        }
    }

    static func stale(_ tab: EditorWindowController, owl: OwlController, id: String, title: String, detail: String?, out: String) {
        guard let window = tab.window else { OwlCheck.finish(out); return }
        owl.hideBubble()
        // The doubled words are gone: the stored range no longer holds them.
        tab.textView.setSelectedRange(NSRange(location: 0, length: (tab.text as NSString).length))
        tab.textView.insertText("Fixed it.\n", replacementRange: tab.textView.selectedRange())
        check(tab.text == "Fixed it.\n", "the text changed (\(tab.text.debugDescription))")
        OwlCheck.after(0.6) {
            owl.hideBubble()
            openPopover(owl) { ok in
                check(ok, "the popover opened again")
                guard let row = owl.popoverRecentRows.first(where: { ($0.accessibilityLabel() ?? "").contains(title) }),
                      let pw = row.window else {
                    check(false, "the row is still listed"); OwlCheck.finish(out); return
                }
                pw.makeFirstResponder(row)
                check(pw.firstResponder === row, "the row takes the focus")
                OwlCheck.key(pw, "\r", code: 36, [])
                AICheck.wait("the stale bubble", timeout: 3, { owl.bubble != nil }) { ok in
                    check(ok && owl.presentedHint?.hint.id == id, "Return on the row showed it again, though stale")
                    check(owl.presentedHint?.hint.title == title && owl.presentedHint?.hint.detail == detail,
                          "with its stored title and detail")
                    check(owl.presentedHint?.documentRange == nil, "and no range")
                    let titles = owl.bubble?.buttons.map(\.title) ?? []
                    check(!titles.contains(String(localized: "Fix it")) && !titles.contains(String(localized: "Show Me")),
                          "no Fix it or Show Me (\(titles))")
                    check(owl.bubble?.isAccessibilityElement() == true || owl.bubble?.accessibilityChildren()?.isEmpty == false,
                          "the bubble is still readable to VoiceOver")
                    shot(window, "\(out)/history-3-stale.png") { OwlCheck.finish(out) }
                }
            }
        }
    }

    // MARK: Auto-review cap

    static func runCap(_ tab: EditorWindowController, out: String) {
        guard let window = tab.window, let owl = tab.owl else { OwlCheck.finish(out); return }
        let hub = OwlHub.shared
        hub.appActiveChanged()
        let size = tab.autoReviewSize
        check(tab.autoReviewCapped, "the log is over the auto-review cap (\(size.utf8Bytes) bytes, \(size.lines) lines)")
        check(!tab.isLargeDocument && !tab.extrasPaused, "but not in large mode (colouring and the owl stay on)")
        AICheck.wait("the AI provider", timeout: 10, { hub.ai.isActive }) { ok in
            check(ok, "the fake AI registered")
            check(hub.ai.isAutomatic, "automatic checks are on (CEDRIC_AI_AUTO=1)")
            check(hub.ai.isAutoReviewCapped(tab.doc.id), "the AI knows the document is capped")
            check(!hub.ai.wantsContext(for: tab.doc.id), "and wants no context for it")
            OwlRulesCheck.typeAtEnd(tab, "still here\n")
            // Pause, min-idle and interval are 0.2 s: an automatic check would have run.
            OwlCheck.after(3) {
                Task { @MainActor in
                    let requests = await hub.ai.scheduler?.requestCount ?? -1
                    check(requests == 0, "opening, typing and pausing started no AI request (\(requests))")
                    check(hub.ai.lastCheck == nil && hub.ai.thinking.isEmpty, "no check ran, the owl never thought")
                    check(EditorWindowController.autoReviewAlertsShown == 0, "and no confirmation popped up on its own")
                    note(tab, owl: owl, window: window, out: out)
                }
            }
        }
    }

    static func note(_ tab: EditorWindowController, owl: OwlController, window: NSWindow, out: String) {
        let hub = OwlHub.shared
        owl.hideBubble()
        openPopover(owl) { ok in
            check(ok, "the popover opened")
            let text = owl.popoverAutoReviewNote ?? ""
            check(text.contains("Auto-review is off for large files"), "the quiet note is there (\(text))")
            check(owl.popoverButtonsFit, "the popover's buttons still fit")
            let status = hub.ai.statusLine(autoReviewCapped: true) ?? ""
            check(status.hasSuffix("checks only when you ask"), "the AI status line doesn't promise a check on a pause (\(status))")
            guard let ask = owl.popoverButton(String(localized: "Ask AI Now")) else {
                check(false, "the popover has Ask AI Now"); OwlCheck.finish(out); return
            }
            shot(owl.popoverWindow, "\(out)/cap-1-popover-note.png") {
                AICheck.press(ask, "Ask AI Now") { window.attachedSheet != nil || !owl.popoverShown }
                AICheck.wait("the confirmation", timeout: 3, { window.attachedSheet != nil }) { ok in
                    check(ok, "Ask AI Now asks first")
                    guard let sheet = window.attachedSheet else { OwlCheck.finish(out); return }
                    let buttons = buttonsIn(sheet.contentView)
                    check(Set(buttons.map(\.title)) == [String(localized: "Cancel"), String(localized: "Ask Anyway")],
                          "Cancel and Ask Anyway (\(buttons.map(\.title)))")
                    check(sheet.defaultButtonCell?.title == String(localized: "Cancel"),
                          "Cancel is the default button (\(sheet.defaultButtonCell?.title ?? "none"))")
                    let texts = textsIn(sheet.contentView).joined(separator: " ")
                    check(texts.contains("KB") && texts.contains("lines") && texts.contains("auto-review is off"),
                          "it names the size and that auto-review is off")
                    shotSheet(sheet, "\(out)/cap-2-confirm.png") {
                        // Cancel (the default button; Return itself needs a key
                        // window, which a locked screen doesn't give the sheet).
                        buttons.first { $0.title == String(localized: "Cancel") }?.performClick(nil)
                        OwlCheck.after(1.0) {
                            Task { @MainActor in
                                let requests = await hub.ai.scheduler?.requestCount ?? -1
                                check(window.attachedSheet == nil, "Cancel closed the confirmation")
                                check(requests == 0 && hub.ai.lastCheck == nil && !tab.autoReviewAskConfirmed,
                                      "and sent nothing, remembered nothing (\(requests) requests)")
                                confirm(tab, owl: owl, window: window, out: out)
                            }
                        }
                    }
                }
            }
        }
    }

    static func confirm(_ tab: EditorWindowController, owl: OwlController, window: NSWindow, out: String) {
        let hub = OwlHub.shared
        openPopover(owl) { _ in
            guard let ask = owl.popoverButton(String(localized: "Ask AI Now")) else {
                check(false, "Ask AI Now again"); OwlCheck.finish(out); return
            }
            AICheck.press(ask, "Ask AI Now") { window.attachedSheet != nil || !owl.popoverShown }
            AICheck.wait("the confirmation", timeout: 3, { window.attachedSheet != nil }) { _ in
                guard let sheet = window.attachedSheet,
                      let go = buttonsIn(sheet.contentView).first(where: { $0.title == String(localized: "Ask Anyway") }) else {
                    check(false, "Ask Anyway"); OwlCheck.finish(out); return
                }
                go.performClick(nil)
                AICheck.wait("the asked-for check", timeout: 10, { hub.ai.lastCheck != nil }) { ok in
                    Task { @MainActor in
                        let requests = await hub.ai.scheduler?.requestCount ?? -1
                        check(ok && requests == 1, "Ask Anyway ran one check (\(requests) requests, \(String(describing: hub.ai.lastCheck?.outcome)))")
                        check(tab.autoReviewAskConfirmed, "remembered for this file")
                        check(!hub.ai.wantsContext(for: tab.doc.id), "and it is still not checked on its own")
                        shot(window, "\(out)/cap-3-asked.png") { OwlCheck.finish(out) }
                    }
                }
            }
        }
    }

    static func buttonsIn(_ v: NSView?) -> [NSButton] {
        guard let v else { return [] }
        var out: [NSButton] = []
        if let b = v as? NSButton, b.bezelStyle != .disclosure, !b.title.isEmpty { out.append(b) }
        for s in v.subviews { out += buttonsIn(s) }
        return out.sorted { $0.frame.minX > $1.frame.minX }
    }

    static func textsIn(_ v: NSView?) -> [String] {
        guard let v else { return [] }
        var out: [String] = []
        if let t = v as? NSTextField { out.append(t.stringValue) }
        for s in v.subviews { out += textsIn(s) }
        return out
    }
}
