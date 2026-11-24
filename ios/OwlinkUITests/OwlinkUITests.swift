import XCTest

/// Drives the real app in the simulator: open a sample, edit, save, reopen;
/// Cedric's offline hint and its fix; the Markdown preview; find.
/// `-OwlinkOpen <name>` opens Documents/<name> (copied from the bundled
/// samples), skipping the document browser.
final class OwlinkUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ name: String, fresh: Bool, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-OwlinkOpen", name, "-OwlinkResetSettings"] + (fresh ? ["-OwlinkFreshSample"] : []) + extra
        app.launch()
        return app
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        let tv = app.textViews["editor.text"]
        XCTAssertTrue(tv.waitForExistence(timeout: 15), "editor didn't open")
        return tv
    }

    /// A finger's tap in the text (its middle). XCUIElement.tap() on the
    /// text view never gives it focus on the iPad simulators (iOS 27.2: no
    /// caret, no keyboard, textViewDidBeginEditing not called), while a tap
    /// at the same point does, on iPhone and iPad alike.
    private func tapText(_ tv: XCUIElement) {
        tv.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Shows the preview and returns its web view: the eye button in the
    /// bar, or on a narrow iPhone the system overflow menu (More ›
    /// Preview › Preview).
    private func showPreview(_ app: XCUIApplication) -> XCUIElement {
        let web = app.webViews["editor.previewWeb"]
        if !web.waitForExistence(timeout: 2) {
            let eye = app.buttons["editor.preview"]
            if eye.exists { eye.tap() } else {
                app.navigationBars.buttons["More"].firstMatch.tap()
                // The eye's own submenu there: its first item is the toggle.
                app.buttons["Preview"].firstMatch.tap()
                let toggle = app.cells.buttons["Preview"].firstMatch
                XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no Preview item in the overflow menu")
                toggle.tap()
            }
        }
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        return web
    }

    /// Leaves read mode (an iPhone opens files read-only): Edit must be
    /// on the bar itself there, not collapsed into the ••• menu behind
    /// disabled Undo/Redo (0.5.2 (17): a 402-pt iPhone hid it).
    private func beginEditing(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let edit = app.navigationBars.buttons["editor.edit"]
        if UIDevice.current.userInterfaceIdiom == .phone {
            XCTAssertTrue(edit.waitForExistence(timeout: 5) && edit.isHittable,
                          "a file opened read-only: no Edit on the iPhone's bar", file: file, line: line)
        }
        if edit.exists, edit.label == "Edit" {
            edit.tap()
            let editing = NSPredicate(format: "label == 'Done'")
            wait(for: [XCTNSPredicateExpectation(predicate: editing, object: edit)], timeout: 5)
        }
    }

    func testOpenEditSaveReopen() throws {
        var app = launch("sample.swift", fresh: true)
        var tv = editor(app)
        XCTAssertTrue((tv.value as? String ?? "").contains("struct Owl"))
        XCTAssertTrue(app.buttons["editor.language"].label.contains("Swift"))
        // Opened read-only on iPhone (the default): Edit first.
        beginEditing(app)
        tapText(tv)
        tv.typeText("\n// typed by the UI test\n")
        XCTAssertTrue((tv.value as? String ?? "").contains("typed by the UI test"))
        // The system overflow menu (the "More" button the system adds).
        app.navigationBars.buttons["More"].firstMatch.tap()
        app.buttons["Save"].firstMatch.tap()
        sleep(2)
        app.terminate()

        app = launch("sample.swift", fresh: false)
        tv = editor(app)
        XCTAssertTrue((tv.value as? String ?? "").contains("typed by the UI test"), "the edit wasn't saved")
        XCTAssertTrue(app.buttons["editor.format"].label.contains("UTF-8"))
    }

    func testHideKeyboardButton() throws {
        let app = launch("sample.swift", fresh: true)
        let tv = editor(app)
        let hide = app.buttons["editor.hideKeyboard"]
        XCTAssertFalse(hide.exists && hide.isHittable)
        // Opened read-only on iPhone: a tap alone brings up no keyboard.
        beginEditing(app)
        tapText(tv)
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "no hide-keyboard button while editing")
        XCTAssertEqual(hide.label, "Hide Keyboard")
        hide.tap()
        let gone = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 5)
        XCTAssertFalse(hide.exists && hide.isHittable, "the hide-keyboard button stayed after the keyboard went")
    }

    func testOwlHintFixesTrailingSpaces() throws {
        let app = launch("sample.swift", fresh: true)
        let tv = editor(app)
        XCTAssertTrue((tv.value as? String ?? "").contains("struct Owl {   "))
        // Opened read-only on iPhone: Fix it changes the text only once
        // editing (in read mode it says "Tap Edit to change the text.").
        beginEditing(app)
        // The owl in the corner shows a badge; tapping him opens his bubble.
        let owl = app.descendants(matching: .any)["owl.sprite"]
        XCTAssertTrue(owl.waitForExistence(timeout: 10), "no owl")
        let badged = NSPredicate(format: "label CONTAINS 'hint'")
        wait(for: [XCTNSPredicateExpectation(predicate: badged, object: owl)], timeout: 10)
        owl.tap()
        let title = app.staticTexts["owl.hint.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10), "no owl hint")
        XCTAssertTrue(title.label.contains("spaces"), "unexpected hint: \(title.label)")
        app.buttons["owl.hint.fix"].tap()
        let fixed = NSPredicate { _, _ in !((tv.value as? String ?? "").contains("struct Owl {   ")) }
        wait(for: [XCTNSPredicateExpectation(predicate: fixed, object: nil)], timeout: 5)
    }

    func testMarkdownPreview() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        XCTAssertTrue(app.buttons["editor.language"].label.contains("Markdown"))
        let web = showPreview(app)
        XCTAssertTrue(web.staticTexts["Owlink for iPhone and iPad"].waitForExistence(timeout: 10))
    }

    /// A web link in the preview asks first (Mac 0.5.2 S1): the tap itself
    /// brings up the prompt, which names the site on its own line and then
    /// shows the whole address; the page never loads in the preview and
    /// there is no Open in Browser button any more. The prompt is captured
    /// as a screenshot attachment and then cancelled (never opened).
    func testWebLinkOpenInBrowserAsksFirst() throws {
        let app = launch("links.md", fresh: true)
        _ = editor(app)
        let web = showPreview(app)
        let link = web.links["The Owlink site"].firstMatch
        XCTAssertTrue(link.waitForExistence(timeout: 10), "no web link in the preview")
        link.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "the tap didn't ask")
        XCTAssertTrue(alert.staticTexts["Open this link?"].exists)
        let site = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Site: example.com")).firstMatch
        XCTAssertTrue(site.exists, "the site on its own line")
        let address = alert.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "https://example.com/owlink")).firstMatch
        XCTAssertTrue(address.exists, "the whole address")
        XCTAssertTrue(alert.buttons["Cancel"].exists && alert.buttons["Open"].exists)
        XCTAssertFalse(app.buttons["preview.nav.openInBrowser"].exists, "no Open in Browser button")
        sleep(1) // the alert's appearance animation
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "preview-external-link-prompt"
        shot.lifetime = .keepAlways
        add(shot)
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 1) && alert.exists, "the prompt stayed")
        XCTAssertEqual(app.state, .runningForeground, "nothing was opened outside the app")
        XCTAssertTrue(link.exists, "the preview still shows the document: the web page did not load in it")
        XCTAssertFalse(app.buttons["preview.nav.back"].exists, "no history step: the Back bar stays hidden")
    }

    /// Find: the magnifying glass in the bar, or on a narrow iPhone bar
    /// (where Edit takes the room) Find in the ••• menu's Find › submenu
    /// (0.5.2 (18): the top-level row opens the submenu, not the navigator).
    func testFindNavigatorOpens() throws {
        let app = launch("sample.swift", fresh: true)
        _ = editor(app)
        let find = app.navigationBars.buttons["editor.find"]
        if find.waitForExistence(timeout: 2) { find.tap() } else {
            app.navigationBars.buttons["More"].firstMatch.tap()
            let submenu = app.collectionViews.buttons["Find"].firstMatch
            XCTAssertTrue(submenu.waitForExistence(timeout: 5), "no Find in the bar or the ••• menu")
            submenu.tap()
            let item = app.collectionViews.buttons["editor.menu.find"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "no Find in the ••• menu's Find › submenu")
            item.tap()
        }
        // The system find navigator's field (a search field, not a text field).
        let field = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND (placeholderValue CONTAINS[c] 'Search' OR placeholderValue CONTAINS[c] 'Find')",
            XCUIElement.ElementType.searchField.rawValue, XCUIElement.ElementType.textField.rawValue)).firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "find navigator didn't open")
        field.typeText("hoot")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'of'")).firstMatch.waitForExistence(timeout: 5))
    }
    /// The editor's ••• menu (the system overflow) and its Preview submenu
    /// for a Markdown document, saved as screenshot attachments (named for
    /// the device: iphone-menu, ipad-menu-preview-submenu, …). "Focus
    /// Preview" is in the Preview submenu only, never in the main list.
    func testOverflowMenuScreenshots() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        func shoot(_ name: String) {
            sleep(1) // the menu's appearance animation
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(device)-\(name)"
            shot.lifetime = .keepAlways
            add(shot)
        }
        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "no ••• button")
        more.tap()
        shoot("menu")
        let preview = app.collectionViews.buttons["Preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5), "no Preview submenu in the ••• menu")
        let mainList = app.collectionViews.buttons.matching(NSPredicate(format: "label == %@", "Focus Preview"))
        XCTAssertEqual(mainList.count, 0, "Focus Preview in the ••• menu's main list")
        // Seven rows (0.5.2 (18)): Save, Share & Export › | Find ›,
        // Preview ›, Ask Cedric | More ›, Settings; eight with Edit first
        // on an iPhone in read mode (its bar button collapsed).
        // (The menu's cells don't expose their titles to XCUITest: counted,
        // and the order checked by where the rows' buttons are.)
        let rows = app.collectionViews.firstMatch.cells.count
        print("MENU-TOP-ROWS \(device): \(rows)")
        let edit = app.collectionViews.buttons["Edit"].firstMatch
        let editInMenu = edit.exists
        XCTAssertEqual(rows, editInMenu ? 8 : 7, "\(rows) rows at the top of the ••• menu (Edit in it: \(editInMenu))")
        var order = ["Save", "Share & Export", "Find", "Preview", "Ask Cedric", "More", "Settings"]
        if editInMenu { order.insert("Edit", at: 0) }
        let ys = order.map { app.collectionViews.buttons[$0].firstMatch.frame.minY }
        XCTAssertEqual(ys, ys.sorted(), "the ••• menu's rows not in the order \(order): \(ys)")
        XCTAssertEqual(Set(ys).count, ys.count, "two rows at the same place: \(ys)")
        if editInMenu { shoot("menu-readmode") }
        preview.tap()
        let focus = app.collectionViews.buttons.matching(NSPredicate(format: "label == %@", "Focus Preview"))
        XCTAssertTrue(focus.firstMatch.waitForExistence(timeout: 5), "no Focus Preview in the Preview submenu")
        XCTAssertEqual(focus.count, 1, "Focus Preview more than once in the Preview submenu")
        shoot("menu-preview-submenu")
        // Share & Export › (0.5.2 (18)): Share…, Print… and the exports.
        closeMenu(app)
        more.tap()
        openSubmenu(app, "Share & Export")
        for item in ["editor.menu.share", "editor.menu.print", "editor.menu.exportHTML", "editor.menu.exportPDF"] {
            XCTAssertTrue(app.collectionViews.buttons[item].firstMatch.waitForExistence(timeout: 5), "no \(item) in Share & Export ›")
        }
        XCTAssertTrue(app.collectionViews.buttons["Share…"].firstMatch.exists, "no Share… in Share & Export ›")
        shoot("menu-share-export")
        // More ›, without Export & Print › now.
        closeMenu(app)
        more.tap()
        openSubmenu(app, "More")
        XCTAssertTrue(app.collectionViews.buttons["Go to Line…"].firstMatch.waitForExistence(timeout: 5), "no Go to Line… in More ›")
        XCTAssertFalse(app.collectionViews.buttons["Export & Print"].firstMatch.exists, "Export & Print › still in More ›")
        shoot("menu-more")
    }

    /// Share… (Share & Export ›) brings up the share sheet with the
    /// document's copy; it is dismissed without sharing.
    func testShareOpensTheShareSheet() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openMore(app)
        openSubmenu(app, "Share & Export")
        let share = app.collectionViews.buttons["editor.menu.share"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 5), "no Share… in Share & Export ›")
        share.tap()
        let sheet = app.descendants(matching: .any)["editor.shareSheet"].firstMatch
        let named = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "README")).firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10) || named.waitForExistence(timeout: 5), "no share sheet")
        shoot("share-sheet")
        let close = app.buttons["Close"].firstMatch
        if close.exists { close.tap() } else { closeMenu(app) }
    }

    // MARK: Settings and the back chevron (0.5.2 (17))

    private var device: String { UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone" }

    private func shoot(_ name: String) {
        sleep(1) // the appearance animation
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "\(device)-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func openMore(_ app: XCUIApplication) {
        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10), "no ••• button")
        more.tap()
    }

    /// An item of the open ••• menu (or of an open submenu). The ••• menu's
    /// top level is short (0.5.2 (18): seven or eight rows) and a swipe on a
    /// list that fits closes the menu, so the list is scrolled only if it
    /// runs past the screen (More › and Language › can, on an iPhone).
    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let item = app.collectionViews.buttons[label].firstMatch
        // Down the list, then back up if a swipe went past it.
        for i in 0..<14 {
            if item.waitForExistence(timeout: 1), item.isHittable { return item }
            guard let list = scrollingMenuList(app) else { break }
            swipeMenu(app, list, up: i < 7)
        }
        XCTAssertTrue(item.exists && item.isHittable, "no \(label) in the ••• menu")
        return item
    }

    /// The open menu's topmost list (a submenu is shown over its parent),
    /// if it is open and its rows run past the part of it on screen; nil if
    /// it fits.
    private func scrollingMenuList(_ app: XCUIApplication) -> XCUIElement? {
        let lists = app.collectionViews.allElementsBoundByIndex
        guard let list = lists.last, list.exists, let shot = try? list.snapshot() else { return nil }
        var rows: [CGRect] = []
        func walk(_ e: XCUIElementSnapshot) {
            if e.elementType == .cell { rows.append(e.frame) }
            e.children.forEach(walk)
        }
        walk(shot)
        guard let top = rows.map(\.minY).min(), let bottom = rows.map(\.maxY).max() else { return nil }
        // The list's own frame runs past the screen (an iPhone's ••• menu:
        // y 62 to 936 on an 874-point screen), so the rows are measured
        // against the part of it in the window.
        let window = app.windows.firstMatch.frame
        let shown = window.isEmpty ? shot.frame : shot.frame.intersection(window)
        return top < shown.minY - 1 || bottom > shown.maxY + 1 ? list : nil
    }

    /// Looks at every row of the open menu: once if it fits, else at each
    /// step of a scroll through it, and back to the top. Only a list that
    /// scrolls is swiped, and only while it is still open.
    private func readOpenMenu(_ app: XCUIApplication, _ what: String, _ look: () -> Void) {
        look()
        guard let list = scrollingMenuList(app) else { return }
        var swipes = 0
        while swipes < 7, list.exists {
            swipeMenu(app, list, up: true)
            swipes += 1
            XCTAssertTrue(list.exists, "\(what) closed on a swipe through it")
            guard list.exists else { return }
            look()
        }
        for _ in 0..<swipes where list.exists { swipeMenu(app, list, up: false) }
    }

    /// A swipe on a menu's list that scrolls, over the rows shown: a drag
    /// from the middle shown row to the top (or bottom) one, by screen
    /// point. An element swipe isn't used: on an iPad mini, Language ›'s
    /// list and its rows (on screen) fail it with "visible frame is empty".
    private func swipeMenu(_ app: XCUIApplication, _ list: XCUIElement, up: Bool) {
        guard let shot = try? list.snapshot() else { return }
        // The rows (cells, in the query's order), top first.
        var rows: [CGRect] = []
        func walk(_ e: XCUIElementSnapshot) {
            if e.elementType == .cell { rows.append(e.frame) }
            e.children.forEach(walk)
        }
        walk(shot)
        let cells = list.cells
        let order = rows.indices.sorted { rows[$0].minY < rows[$1].minY }
        // The shown run: from the first hittable row to the last.
        var shown: [CGRect] = []
        for i in order {
            if cells.element(boundBy: i).isHittable { shown.append(rows[i]) } else if !shown.isEmpty { break }
        }
        guard shown.count >= 3 else {
            if up { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
            return
        }
        let origin = app.coordinate(withNormalizedOffset: .zero)
        func point(_ r: CGRect) -> XCUICoordinate { origin.withOffset(CGVector(dx: r.midX, dy: r.midY)) }
        let from = shown[shown.count / 2], to = up ? shown[0] : shown[shown.count - 1]
        point(from).press(forDuration: 0.05, thenDragTo: point(to), withVelocity: .slow, thenHoldForDuration: 0)
        sleep(1) // the scroll's deceleration
    }

    /// Opens a submenu of the open ••• menu (More ›, Share & Export ›, …).
    private func openSubmenu(_ app: XCUIApplication, _ label: String) {
        menuItem(app, label).tap()
        sleep(1) // the submenu's animation
    }

    /// Closes an open menu by tapping outside it (on the status line).
    private func closeMenu(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)).tap()
        sleep(1)
    }

    /// ⌘, as a hardware-keyboard event (not a menu tap).
    private func commandComma(_ app: XCUIApplication) {
        app.typeKey(",", modifierFlags: .command)
    }

    /// A lone Shift press: no command, no text. On the iOS 27.2 iPad
    /// simulators a ⌘-chord XCUITest synthesizes is dropped until the
    /// launch has had a plain key event: with nothing before it, ⌘, didn't
    /// open Settings (no sheet anywhere), a second ⌘, didn't either, and
    /// typing in an earlier launch didn't help; after one Shift press ⌘,
    /// opened Settings with no sheet, after Ask Cedric's sheet closed and
    /// over the sheet (same app build; gate-ipad-mini and gate-ipad-pro-13,
    /// 2026-11-24). This is an XCUITest-only artefact, so the prime is kept.
    /// AXe v2.1.1's real HID `key-combo --modifiers 227 --key 54` (no prime)
    /// opened Owlink's Settings on a fresh launch: twice on gate-ipad-pro-11,
    /// and on all four gate devices in the 3b9e5a9 gate run after the •••
    /// menu closed and after Ask Cedric closed (/tmp/ios-gate-run-20261124-065834).
    /// A real keyboard sends ⌘'s own key-down first, as AXe does.
    private func primeHardwareKeyboard(_ app: XCUIApplication) {
        app.typeKey(XCUIKeyboardKey.shift.rawValue, modifierFlags: [])
        sleep(1)
    }

    private func settingsShown(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["settings.font"].waitForExistence(timeout: 8)
    }

    private func closeSettings(_ app: XCUIApplication) {
        let done = app.navigationBars.buttons["Done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 5), "no Done in Settings")
        done.tap()
        let gone = NSPredicate { _, _ in !app.descendants(matching: .any)["settings.font"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 8)
    }

    /// Ask Cedric from the ••• menu. As a sheet: an iPad at regular width
    /// docks it beside the text, so there it is popped out into the sheet.
    private func openAsk(_ app: XCUIApplication, sheet: Bool) {
        openMore(app)
        menuItem(app, "Ask Cedric").tap()
        let done = app.buttons["ask.done"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10), "Ask Cedric didn't open")
        if sheet {
            // iPad at regular width docks Ask Cedric (ask.panel) and offers
            // Pop Out (ask.popOut). ask.done exists in both presentations, so
            // a missing identifier must not let a "sheet" test pass against
            // the docked panel: both must be present, Pop Out is tapped, and
            // both must then be gone. On iPhone, Ask is already a sheet (no
            // panel). The sheet is independently the absence of ask.panel.
            let panel = app.descendants(matching: .any)["ask.panel"].firstMatch
            if device == "ipad" {
                XCTAssertTrue(panel.waitForExistence(timeout: 5),
                              "Ask Cedric didn't dock (no ask.panel); can't open the sheet")
                let popOut = app.buttons["ask.popOut"].firstMatch
                XCTAssertTrue(popOut.waitForExistence(timeout: 5),
                              "Ask Cedric's docked panel has no Pop Out")
                popOut.tap()
                sleep(1)
                XCTAssertFalse(app.buttons["ask.popOut"].firstMatch.exists,
                               "Pop Out is still on screen; the sheet didn't open")
            }
            XCTAssertFalse(panel.exists, "Ask Cedric is still the docked panel; the sheet didn't open")
        }
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Ask Cedric didn't stay open")
    }

    private func closeAskWithDone(_ app: XCUIApplication) {
        app.buttons["ask.done"].firstMatch.tap()
        let gone = NSPredicate { _, _ in !app.buttons["ask.done"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 8)
    }

    /// Swipe-down on the sheet (from just above its Done button).
    private func closeAskBySwipe(_ app: XCUIApplication) {
        let done = app.buttons["ask.done"].firstMatch
        let window = app.windows.firstMatch
        let top = window.coordinate(withNormalizedOffset: .zero)
        let y = done.frame.minY - 4
        let start = top.withOffset(CGVector(dx: window.frame.midX, dy: max(y, 0)))
        let end = top.withOffset(CGVector(dx: window.frame.midX, dy: window.frame.maxY - 2))
        start.press(forDuration: 0.1, thenDragTo: end)
        let gone = NSPredicate { _, _ in !app.buttons["ask.done"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 8)
    }

    /// The back chevron closes the document: the file list (the document
    /// browser, with its own Settings button) comes back.
    private func assertBackReturnsToFiles(_ app: XCUIApplication, _ state: String, file: StaticString = #filePath, line: UInt = #line) {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable, "\(state): no back chevron", file: file, line: line)
        back.tap()
        XCTAssertTrue(app.descendants(matching: .any)["browser.settings"].waitForExistence(timeout: 10),
                      "\(state): the back chevron didn't return to the file list", file: file, line: line)
        XCTAssertFalse(app.textViews["editor.text"].exists, "\(state): the editor is still open", file: file, line: line)
    }

    func testSettingsOpensFromTheMenuWithoutCedric() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openMore(app)
        menuItem(app, "Settings").tap()
        XCTAssertTrue(settingsShown(app), "Settings didn't open from the ••• menu (Ask Cedric closed)")
        shoot("settings-from-menu")
        closeSettings(app)
        // And again after Ask Cedric was opened and closed.
        openAsk(app, sheet: true)
        closeAskWithDone(app)
        openMore(app)
        menuItem(app, "Settings").tap()
        XCTAssertTrue(settingsShown(app), "Settings didn't open from the ••• menu after Ask Cedric closed")
        closeSettings(app)
    }

    /// The iPad menu bar's commands reach the editor with nothing in it
    /// first responder (a document just opened, nothing tapped): ⇧⌘P shows
    /// the preview, and ⌘, opens Owlink's Settings rather than sending
    /// Owlink to the system Settings app.
    func testMenuBarCommandsReachTheEditor() throws {
        guard device == "ipad" else { throw XCTSkip("the menu bar's keys: iPad") }
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        sleep(2) // the simulator hands synthesized keys to the app once it has settled
        app.typeKey("p", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.webViews["editor.previewWeb"].waitForExistence(timeout: 5), "⇧⌘P didn't reach the editor")
        app.typeKey(",", modifierFlags: .command)
        XCTAssertEqual(app.state, .runningForeground, "⌘, left Owlink (the system Settings app)")
        XCTAssertTrue(settingsShown(app), "⌘, didn't open Owlink's Settings")
        shoot("settings-from-command-comma")
        closeSettings(app)
    }

    /// Settings over Ask Cedric, which stays open: Ask Cedric's own button
    /// (shown with no model ready), else the ••• menu (above the iPhone's
    /// half-height sheet; beside the iPad's docked panel).
    func testSettingsOpensWithCedricOpen() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openAsk(app, sheet: false)
        let open = app.buttons["Open Settings"].firstMatch
        if open.waitForExistence(timeout: 3) { open.tap() } else {
            openMore(app)
            menuItem(app, "Settings").tap()
        }
        XCTAssertTrue(settingsShown(app), "Settings didn't open with Ask Cedric open")
        shoot("settings-over-ask-cedric")
        closeSettings(app)
        XCTAssertTrue(app.buttons["ask.done"].firstMatch.waitForExistence(timeout: 5), "Ask Cedric went with Settings")
        closeAskWithDone(app)
        assertBackReturnsToFiles(app, "after Settings over Ask Cedric")
    }

    /// Waits until Owlink is in front and Ask Cedric's sheet has stopped
    /// moving (Done hittable, its frame the same on two reads), so a tap
    /// that follows is the one being tested, not one that activates the
    /// window or lands mid-animation.
    private func waitForAskSheetToSettle(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "Owlink isn't in front", file: file, line: line)
        let done = app.buttons["ask.done"].firstMatch
        var last = CGRect.null
        for _ in 0..<40 {
            let frame = done.frame
            if done.exists, done.isHittable, frame == last { return }
            last = frame
            usleep(250_000)
        }
        XCTFail("Ask Cedric's sheet didn't settle", file: file, line: line)
    }

    /// One tap where the back chevron is (XCUITest may count the undimmed
    /// sheet's container as covering it; a finger isn't stopped by it).
    private func tapBackOnce(_ app: XCUIApplication) {
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no back chevron")
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// The sheet stops at half height, undimmed: the back chevron stays
    /// tappable over it. One tap, once the sheet has settled, closes the
    /// document (sheet and all). (Codex review of 0.5.2 (17), should-fix
    /// 3: a second tap is no longer accepted.)
    func testBackChevronWithAskCedricOpen() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openAsk(app, sheet: true)
        waitForAskSheetToSettle(app)
        tapBackOnce(app)
        XCTAssertTrue(app.descendants(matching: .any)["browser.settings"].waitForExistence(timeout: 10),
                      "Ask Cedric open: one tap on the back chevron didn't return to the file list")
        XCTAssertFalse(app.textViews["editor.text"].exists, "the editor is still open")
    }

    /// Unsaved changes ("Save automatically" off) with Ask Cedric open:
    /// one tap asks Save / Don't Save over the sheet; Cancel keeps the
    /// document and Ask Cedric, and the chevron still works; Don't Save
    /// returns to the file list.
    func testBackChevronWithAskCedricOpenAndUnsavedChanges() throws {
        let app = launch("README.md", fresh: true, extra: ["-ios.saveAutomatically", "<false/>"])
        _ = editor(app)
        // Opened read-only on iPhone: Edit (in the bar, or collapsed into
        // the ••• menu on a narrow bar).
        let edit = app.buttons["editor.edit"]
        if edit.exists {
            if edit.label == "Edit" { edit.tap() }
        } else {
            openMore(app)
            let item = app.collectionViews.buttons["Edit"].firstMatch
            if item.waitForExistence(timeout: 3) { item.tap() } else { closeMenu(app) }
        }
        // An unsaved change without the keyboard (typing doesn't reach the
        // text view in this simulator: see testHideKeyboardButton): CRLF
        // line endings, an undoable change written on Save.
        openMore(app)
        // In More › since 0.5.2 (18).
        openSubmenu(app, "More")
        menuItem(app, "Encoding and Line Endings").tap()
        let crlf = app.buttons["CRLF"].firstMatch
        XCTAssertTrue(crlf.waitForExistence(timeout: 5), "no CRLF item")
        crlf.tap()
        let change = app.alerts.buttons["Change"].firstMatch
        XCTAssertTrue(change.waitForExistence(timeout: 5), "no line-ending confirmation")
        change.tap()
        XCTAssertTrue(app.alerts.count == 0 || !change.exists)
        openAsk(app, sheet: true)
        waitForAskSheetToSettle(app)
        tapBackOnce(app)
        let dontSave = app.buttons["Don’t Save"].firstMatch
        XCTAssertTrue(dontSave.waitForExistence(timeout: 5), "one tap didn't ask about the unsaved changes")
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(app.buttons["ask.done"].firstMatch.waitForExistence(timeout: 5), "Cancel took Ask Cedric away")
        XCTAssertTrue(app.textViews["editor.text"].exists, "Cancel closed the document")
        waitForAskSheetToSettle(app)
        tapBackOnce(app)
        XCTAssertTrue(dontSave.waitForExistence(timeout: 5), "after Cancel the back chevron did nothing")
        dontSave.tap()
        XCTAssertTrue(app.descendants(matching: .any)["browser.settings"].waitForExistence(timeout: 10),
                      "Don't Save didn't return to the file list")
        XCTAssertFalse(app.textViews["editor.text"].exists, "the editor is still open")
    }

    /// Settings opened over the Ask Cedric sheet (from the ••• menu above
    /// it), closed, Ask Cedric closed, then the back chevron. On every
    /// device: the sheet stops at half height, undimmed, with ••• in view
    /// above it (iPhone; an iPad's popped-out sheet too). XCUITest may
    /// count the sheet's container as covering the button, so the tap
    /// goes to its coordinate, as a finger's would.
    func testSettingsOverAskCedricThenBack() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openAsk(app, sheet: true)
        waitForAskSheetToSettle(app)
        let more = app.navigationBars.buttons["More"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no ••• above Ask Cedric's sheet")
        more.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        menuItem(app, "Settings").tap()
        XCTAssertTrue(settingsShown(app), "Settings didn't open with Ask Cedric open")
        closeSettings(app)
        XCTAssertTrue(app.buttons["ask.done"].waitForExistence(timeout: 5), "Ask Cedric went with Settings")
        closeAskWithDone(app)
        assertBackReturnsToFiles(app, "Settings over Ask Cedric")
    }

    func testBackChevronAfterAskCedricDone() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openAsk(app, sheet: true)
        closeAskWithDone(app)
        assertBackReturnsToFiles(app, "Ask Cedric, Done")
    }

    func testBackChevronAfterAskCedricSwipeDown() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openAsk(app, sheet: true)
        closeAskBySwipe(app)
        assertBackReturnsToFiles(app, "Ask Cedric, swipe down")
    }

    func testBackChevronAfterAskCedricPanel() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openAsk(app, sheet: false)
        closeAskWithDone(app)
        assertBackReturnsToFiles(app, "Ask Cedric (panel on iPad), Done")
    }

    func testBackChevronAfterSettings() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openMore(app)
        menuItem(app, "Settings").tap()
        XCTAssertTrue(settingsShown(app), "Settings didn't open")
        closeSettings(app)
        assertBackReturnsToFiles(app, "Settings")
    }

    func testBackChevronAfterPreviewAndFocusPreview() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        // Shown and hidden again from the ••• menu's Preview submenu.
        for _ in 0..<2 {
            openMore(app)
            menuItem(app, "Preview").tap()
            let toggle = app.buttons["editor.menu.preview"].firstMatch
            XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no Preview toggle in the Preview submenu")
            toggle.tap()
            sleep(1)
        }
        // Focus Preview in and out.
        openMore(app)
        menuItem(app, "Preview").tap()
        let focus = app.buttons["editor.menu.focusPreview"].firstMatch
        XCTAssertTrue(focus.waitForExistence(timeout: 5), "no Focus Preview in the Preview submenu")
        focus.tap()
        let edit = app.buttons["editor.focusDone"]
        XCTAssertTrue(edit.waitForExistence(timeout: 5), "Focus Preview didn't start")
        edit.tap()
        sleep(1)
        assertBackReturnsToFiles(app, "preview shown/hidden and Focus Preview")
    }

    func testBackChevronAfterMenus() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openMore(app)
        closeMenu(app)
        openMore(app)
        menuItem(app, "Preview").tap()
        sleep(1)
        closeMenu(app)
        openMore(app)
        // In More › since 0.5.2 (18).
        openSubmenu(app, "More")
        menuItem(app, "Writing Mode").tap()
        sleep(1)
        closeMenu(app)
        assertBackReturnsToFiles(app, "••• menu and its submenus")
    }

    func testBackChevronAfterDetachingThePreview() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openMore(app)
        menuItem(app, "Preview").tap()
        let detach = app.collectionViews.buttons["Open Preview in New Window"].firstMatch
        guard detach.waitForExistence(timeout: 3) else {
            closeMenu(app)
            throw XCTSkip("no detached preview here (iPhone)")
        }
        detach.tap()
        let detached = app.descendants(matching: .any)["detachedPreview.web"]
        XCTAssertTrue(detached.waitForExistence(timeout: 10), "no preview window")
        shoot("detached-preview")
        // Without Stage Manager the new window takes the screen: closing
        // it brings the editor's window back.
        if !app.navigationBars.buttons["BackButton"].firstMatch.isHittable {
            let close = app.buttons["detachedPreview.close"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5), "no Close in the preview window")
            close.tap()
            XCTAssertTrue(app.textViews["editor.text"].waitForExistence(timeout: 10), "the editor's window didn't come back")
            // The editor's window comes back inactive (XCUITest reports the
            // app in the background): a first tap would only activate it.
            if app.state != .runningForeground { app.activate() }
        }
        assertBackReturnsToFiles(app, "detached preview")
    }

    // MARK: Format bar under Ask Cedric, front matter (0.5.2 (17))

    private func formatBar(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'contextbar.'")).firstMatch
    }

    /// Editing with the keyboard (and so the format bar) up, on every
    /// device. (It used to skip on iPad as "hardware keyboard, no input
    /// accessory": the real cause was XCUIElement.tap() not focusing the
    /// text there; with a real tap the iPad shows the format bar.)
    private func startTyping(_ app: XCUIApplication, _ tv: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        beginEditing(app, file: file, line: line)
        tapText(tv)
        XCTAssertTrue(formatBar(app).waitForExistence(timeout: 8), "no format bar while editing Markdown", file: file, line: line)
    }

    private func waitGone(_ e: XCUIElement, _ message: String) {
        let gone = NSPredicate { _, _ in !e.exists || !e.isHittable }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 8)
        XCTAssertFalse(e.exists && e.isHittable, message)
    }

    func testFormatBarHiddenUnderAskCedric() throws {
        let app = launch("README.md", fresh: true)
        let tv = editor(app)
        startTyping(app, tv)
        openAsk(app, sheet: true)
        waitGone(formatBar(app), "the format bar shows under Ask Cedric")
        // Not merely covered: off the keyboard altogether (an iPad's sheet
        // leaves the bottom of the screen in view).
        XCTAssertFalse(formatBar(app).exists, "the format bar is still on screen under Ask Cedric")
        shoot("ask-cedric-no-format-bar")
        closeAskWithDone(app)
        tapText(tv)
        XCTAssertTrue(formatBar(app).waitForExistence(timeout: 8), "the format bar didn't come back after Done")
        shoot("format-bar-restored")
        // And after a swipe down.
        openAsk(app, sheet: true)
        waitGone(formatBar(app), "the format bar shows under Ask Cedric (again)")
        // Not merely covered: off the keyboard altogether (an iPad's sheet
        // leaves the bottom of the screen in view).
        XCTAssertFalse(formatBar(app).exists, "the format bar is still on screen under Ask Cedric (again)")
        closeAskBySwipe(app)
        tapText(tv)
        XCTAssertTrue(formatBar(app).waitForExistence(timeout: 8), "the format bar didn't come back after a swipe down")
    }

    /// The preview's front matter: one line, a disclosure VoiceOver reads
    /// with "Front matter" and the title; a tap opens it.
    func testFrontMatterCollapsedAndExpanded() throws {
        let app = launch("front-matter.md", fresh: true)
        _ = editor(app)
        let web = showPreview(app)
        let summary = web.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Front matter' AND label CONTAINS 'Owls of the World'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 10), "no Front matter · title summary")
        print("FRONTMATTER-SUMMARY type=\(summary.elementType.rawValue) label=\(summary.label) value=\(String(describing: summary.value))")
        XCTAssertTrue([.button, .disclosureTriangle].contains(summary.elementType), "the summary isn't a button: \(summary.elementType.rawValue)")
        XCTAssertFalse(web.staticTexts["A barn owl at dusk"].exists, "the values show while collapsed")
        shoot("front-matter-collapsed")
        try auditPreview(app, web, "collapsed front matter")
        summary.tap()
        XCTAssertTrue(web.staticTexts["A barn owl at dusk"].waitForExistence(timeout: 5), "a tap didn't open the front matter")
        shoot("front-matter-expanded")
        try auditPreview(app, web, "expanded front matter")
    }

    /// The system accessibility audit, on the preview: every issue it
    /// finds on an element inside the preview's web view fails the test.
    /// One narrow exception: "Label not human-readable" on a label that is
    /// exactly one of the document's own front-matter values (the sample's
    /// `icon: owl.png`). The preview shows the writer's text as written, and
    /// VoiceOver reading "owl.png" is right. Issues on the rest of the
    /// screen (the editor's bar and status line, the text) and issues the
    /// audit can't place on an element are printed, not failed: they
    /// aren't this test's subject.
    private func auditPreview(_ app: XCUIApplication, _ web: XCUIElement, _ state: String,
                              documentValues: Set<String> = ["owl.png", "/", "/notes"]) throws {
        let area = web.frame
        var inPreview: [String] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            let element = issue.element
            let frame = element?.frame ?? .null
            let label = element?.label ?? ""
            let line = "\(state): \(issue.auditType.rawValue) \(issue.compactDescription) (\(issue.detailedDescription)) — " +
                "\(element.map { "\($0.elementType.rawValue) '\($0.label)' \(frame)" } ?? "no element")"
            let inside = !frame.isNull && !frame.isEmpty && area.contains(CGPoint(x: frame.midX, y: frame.midY))
            let documentText = issue.auditType == .sufficientElementDescription && documentValues.contains(label)
            let verdict = !inside ? (element == nil ? "unplaced" : "outside") : documentText ? "PREVIEW-document-text" : "PREVIEW"
            print("A11Y-AUDIT \(verdict) \(line)")
            if inside && !documentText { inPreview.append(line) }
            return !(inside && !documentText)
        }
        XCTAssertTrue(inPreview.isEmpty, "accessibility audit issues in the preview: \(inPreview)")
    }

    // MARK: ⌘, from the hardware keyboard (iPad, 0.5.2 (16) findings)

    /// ⌘, opens Owlink's Settings as a real key event: right after the •••
    /// menu closes, right after Settings (a sheet) closes, with Ask Cedric
    /// docked beside the text, over Ask Cedric's sheet, and right after
    /// Ask Cedric closes. Never the system Settings app.
    func testCommandCommaOpensSettingsOnIPad() throws {
        guard device == "ipad" else { throw XCTSkip("⌘, from a hardware keyboard: the iPad gate devices") }
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        sleep(2) // the simulator hands synthesized keys to the app once it has settled
        primeHardwareKeyboard(app)
        func expectSettings(_ state: String, askStays: Bool = false) {
            commandComma(app)
            XCTAssertEqual(app.state, .runningForeground, "\(state): ⌘, left Owlink (the system Settings app)")
            XCTAssertTrue(settingsShown(app), "\(state): ⌘, didn't open Owlink's Settings")
            closeSettings(app)
            if askStays {
                XCTAssertTrue(app.buttons["ask.done"].firstMatch.waitForExistence(timeout: 5), "\(state): Ask Cedric went with Settings")
            }
        }
        openMore(app)
        closeMenu(app)
        expectSettings("right after the ••• menu closed")
        expectSettings("right after Settings closed")
        openAsk(app, sheet: false)
        expectSettings("Ask Cedric open (docked)", askStays: true)
        closeAskWithDone(app)
        expectSettings("right after Ask Cedric (docked) closed")
        openAsk(app, sheet: true)
        waitForAskSheetToSettle(app)
        expectSettings("over Ask Cedric's sheet", askStays: true)
        shoot("settings-over-ask-sheet-command-comma")
        closeAskWithDone(app)
        expectSettings("right after Ask Cedric's sheet closed")
        assertBackReturnsToFiles(app, "after ⌘, in every state")
    }

    /// ⌘, as the first shortcut of a launch, right after a sheet closed:
    /// Ask Cedric's sheet opens from the ••• menu and closes with Done,
    /// then ⌘, is the first key command the app gets. Twice, each in a new
    /// launch, so it is never only the simulator session's first launch.
    func testCommandCommaFirstInALaunchAfterAskSheetClosed() throws {
        guard device == "ipad" else { throw XCTSkip("⌘, from a hardware keyboard: the iPad gate devices") }
        for launchNumber in 1...2 {
            let app = launch("README.md", fresh: true)
            _ = editor(app)
            sleep(2) // the simulator hands synthesized keys to the app once it has settled
            primeHardwareKeyboard(app) // not a shortcut: ⌘, below is the launch's first
            openAsk(app, sheet: true)
            waitForAskSheetToSettle(app)
            closeAskWithDone(app)
            commandComma(app)
            XCTAssertEqual(app.state, .runningForeground, "launch \(launchNumber): ⌘, left Owlink")
            XCTAssertTrue(settingsShown(app), "launch \(launchNumber): ⌘, first after Ask Cedric's sheet closed didn't open Settings")
            closeSettings(app)
            app.terminate()
        }
    }

    /// ⌘, as the first shortcut of a launch, over Ask Cedric's sheet (the
    /// case that failed on launches after the first in a simulator session;
    /// testCommandCommaOpensSettingsOnIPad presses ⌘, earlier in its launch).
    func testCommandCommaFirstInALaunchOverAskSheet() throws {
        guard device == "ipad" else { throw XCTSkip("⌘, from a hardware keyboard: the iPad gate devices") }
        for launchNumber in 1...2 {
            let app = launch("README.md", fresh: true)
            _ = editor(app)
            sleep(2)
            primeHardwareKeyboard(app) // not a shortcut: ⌘, below is the launch's first
            openAsk(app, sheet: true)
            waitForAskSheetToSettle(app)
            commandComma(app)
            XCTAssertEqual(app.state, .runningForeground, "launch \(launchNumber): ⌘, left Owlink")
            XCTAssertTrue(settingsShown(app), "launch \(launchNumber): ⌘, first over Ask Cedric's sheet didn't open Settings")
            closeSettings(app)
            XCTAssertTrue(app.buttons["ask.done"].firstMatch.waitForExistence(timeout: 5), "launch \(launchNumber): Ask Cedric went with Settings")
            app.terminate()
        }
    }

    // MARK: Focus Preview listed once (0.5.2 (16) findings)

    /// Focus Preview is listed once: never in the ••• menu's main list (not
    /// as a collapsed bar button either, with the preview off or on) nor in
    /// More › or its submenus, once in its Preview submenu, at most once in
    /// the bar. On every device
    /// the gate runs (iPhone, iPad mini, iPad Pro 13).
    func testFocusPreviewListedOnce() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        let named = NSPredicate(format: "label == %@", "Focus Preview")
        for previewOn in [false, true] {
            let state = previewOn ? "preview on" : "preview off"
            XCTAssertLessThanOrEqual(app.navigationBars.descendants(matching: .any).matching(named).count, 1,
                                     "\(state): Focus Preview more than once in the bar")
            openMore(app)
            let preview = app.collectionViews.buttons["Preview"].firstMatch
            XCTAssertTrue(preview.waitForExistence(timeout: 5), "\(state): no Preview submenu in the ••• menu")
            // The whole main list (seven or eight rows since 0.5.2 (18):
            // scrolled through only if it doesn't fit).
            var seen = 0
            readOpenMenu(app, "\(state): the ••• menu") {
                seen = max(seen, app.collectionViews.descendants(matching: .any).matching(named).count)
            }
            XCTAssertEqual(seen, 0, "\(state): Focus Preview in the ••• menu's main list")
            // More › and each submenu in it: no Focus Preview either.
            for nested in [nil, "View", "Writing Mode", "Language", "Encoding and Line Endings",
                           "Indentation", "Bookmarks", "Folding"] as [String?] {
                if nested != nil {
                    closeMenu(app)
                    openMore(app)
                }
                openSubmenu(app, "More")
                XCTAssertTrue(app.collectionViews.buttons["Go to Line…"].firstMatch.waitForExistence(timeout: 5),
                              "\(state): More › didn't open")
                if let nested { openSubmenu(app, nested) }
                let place = nested.map { "More › \($0) ›" } ?? "More ›"
                var seenHere = 0
                readOpenMenu(app, "\(state): \(place)") {
                    seenHere = max(seenHere, app.collectionViews.descendants(matching: .any).matching(named).count)
                }
                XCTAssertEqual(seenHere, 0, "\(state): Focus Preview in \(place)")
            }
            closeMenu(app)
            openMore(app)
            menuItem(app, "Preview").tap()
            let focus = app.collectionViews.buttons.matching(named)
            XCTAssertTrue(focus.firstMatch.waitForExistence(timeout: 5), "\(state): no Focus Preview in the Preview submenu")
            XCTAssertEqual(app.collectionViews.descendants(matching: .any).matching(named).count, 1,
                           "\(state): Focus Preview more than once in the Preview submenu")
            shoot("focus-preview-once-\(previewOn ? "on" : "off")")
            if !previewOn {
                // The submenu's Preview toggle: shown for the second round.
                app.buttons["editor.menu.preview"].firstMatch.tap()
                XCTAssertTrue(app.webViews["editor.previewWeb"].waitForExistence(timeout: 10), "the preview didn't show")
            } else {
                closeMenu(app)
            }
        }
    }

    // MARK: US English on the real screens (0.5.2 (16) findings)

    /// British-only stems, as in USEnglishCopyTests' source scan (US:
    /// summarize, color, center, license…), word-aware, any case.
    private static let british = try! NSRegularExpression(pattern: #"(?i)\b\w*(summaris|organis|customis|recognis|optimis|initialis|normalis|authoris|synchronis|categoris|visualis|prioritis|standardis|minimis|maximis|emphasis(e|ing)|apologis|colour|behaviour|favourit|honour|neighbour|catalogue|cancell(ed|ing)|labell(ed|ing)|centre|licence)\w*"#)

    /// The visible copy now (labels, titles, placeholders, but not the
    /// document's own text in the editor or the preview).
    private func visibleCopy(_ app: XCUIApplication) -> [String] {
        guard let root = try? app.snapshot() else { return [] }
        var out: [String] = []
        func walk(_ e: XCUIElementSnapshot) {
            if [.textView, .webView, .keyboard].contains(e.elementType) { return }
            for t in [e.label, e.title, e.placeholderValue ?? ""] where !t.isEmpty { out.append(t) }
            e.children.forEach(walk)
        }
        walk(root)
        return out
    }

    private func britishSpellings(_ copy: [String]) -> [String] {
        copy.flatMap { text -> [String] in
            let ns = text as NSString
            return Self.british.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                "\(ns.substring(with: $0.range)) in “\(text)”"
            }
        }
    }

    func testTheVisibleCopyScanCatchesBritishSpellings() {
        XCTAssertEqual(britishSpellings(["Summarise", "Summarising…", "Text colour", "CENTRE"]).count, 4)
        XCTAssertTrue(britishSpellings(["Summarize", "Color", "Center", "License", "Centered"]).isEmpty)
    }

    /// Settings, the ••• menu (and its Preview submenu), the format bar,
    /// and Ask Cedric, opened for real: no Summarise, colour, centre….
    func testVisibleCopyIsUSEnglish() throws {
        let app = launch("README.md", fresh: true)
        let tv = editor(app)
        var found: [String: [String]] = [:]
        func scan(_ screen: String) {
            let bad = britishSpellings(visibleCopy(app))
            if !bad.isEmpty { found[screen, default: []] += bad }
        }
        scan("editor")
        // The ••• menu (scrolled through only if it doesn't fit), and its
        // Preview submenu.
        openMore(app)
        XCTAssertTrue(app.collectionViews.buttons["Preview"].firstMatch.waitForExistence(timeout: 5), "no ••• menu")
        readOpenMenu(app, "the ••• menu") { scan("••• menu") }
        menuItem(app, "Preview").tap()
        sleep(1)
        scan("••• › Preview")
        closeMenu(app)
        // Settings, scrolled through.
        openMore(app)
        menuItem(app, "Settings").tap()
        XCTAssertTrue(settingsShown(app), "Settings didn't open")
        let form = app.collectionViews.firstMatch.exists ? app.collectionViews.firstMatch : app.tables.firstMatch
        for _ in 0..<10 { scan("Settings"); form.swipeUp(velocity: .slow) }
        scan("Settings")
        closeSettings(app)
        // Ask Cedric (its action buttons: Explain, Summarize, …).
        openAsk(app, sheet: true)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier == 'ask.action'")).firstMatch.waitForExistence(timeout: 5),
                      "no Ask Cedric actions")
        scan("Ask Cedric")
        shoot("ask-cedric-us-english")
        closeAskWithDone(app)
        // The format bar (the keyboard's input accessory), last: the
        // keyboard would sit over the menus' taps.
        startTyping(app, tv)
        scan("format bar")
        XCTAssertTrue(found.isEmpty, "British spellings on screen: \(found)")
    }

    // MARK: Front matter remembered (0.5.2 (16) findings)

    private func hidePreview(_ app: XCUIApplication) {
        openMore(app)
        menuItem(app, "Preview").tap()
        let toggle = app.buttons["editor.menu.preview"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "no Preview toggle in the Preview submenu")
        toggle.tap()
        let gone = NSPredicate { _, _ in !app.webViews["editor.previewWeb"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 8)
    }

    /// The front matter stays as it was left, open or closed, when the
    /// preview is hidden and shown again.
    func testFrontMatterStateKeptAcrossPreviewHideShow() throws {
        let app = launch("front-matter.md", fresh: true)
        _ = editor(app)
        func summary(_ web: XCUIElement) -> XCUIElement {
            web.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'Front matter' AND label CONTAINS 'Owls of the World'")).firstMatch
        }
        var web = showPreview(app)
        XCTAssertTrue(summary(web).waitForExistence(timeout: 10), "no Front matter · title summary")
        XCTAssertFalse(web.staticTexts["A barn owl at dusk"].exists, "the values show while collapsed")
        summary(web).tap()
        XCTAssertTrue(web.staticTexts["A barn owl at dusk"].waitForExistence(timeout: 5), "a tap didn't open the front matter")
        hidePreview(app)
        web = showPreview(app)
        XCTAssertTrue(summary(web).waitForExistence(timeout: 10), "no Front matter summary after showing the preview again")
        XCTAssertTrue(web.staticTexts["A barn owl at dusk"].waitForExistence(timeout: 5),
                      "opened, the preview hidden and shown: the front matter came back closed")
        shoot("front-matter-kept-open")
        summary(web).tap()
        let closed = NSPredicate { _, _ in !web.staticTexts["A barn owl at dusk"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 5)
        hidePreview(app)
        web = showPreview(app)
        XCTAssertTrue(summary(web).waitForExistence(timeout: 10), "no Front matter summary after showing the preview again")
        sleep(1)
        XCTAssertFalse(web.staticTexts["A barn owl at dusk"].exists,
                       "closed, the preview hidden and shown: the front matter came back open")
    }

    // MARK: The gate's screenshots (Scripts/ios-gate.sh)

    private func gateShot(_ name: String) {
        sleep(1)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "gate-\(name)"
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The main screens, as attachments named gate-<screen>, which
    /// Scripts/ios-gate.sh saves per build and device and compares with
    /// the previous build's.
    func testGateScreenshots() throws {
        var app = launch("README.md", fresh: true)
        _ = editor(app)
        sleep(1)
        gateShot("1-editor")
        openMore(app)
        gateShot("2-menu")
        closeMenu(app)
        openMore(app)
        menuItem(app, "Settings").tap()
        XCTAssertTrue(settingsShown(app), "Settings didn't open")
        gateShot("3-settings")
        closeSettings(app)
        openAsk(app, sheet: true)
        waitForAskSheetToSettle(app)
        gateShot("4-ask-cedric")
        closeAskWithDone(app)
        app.terminate()
        app = launch("front-matter.md", fresh: true)
        _ = editor(app)
        let web = showPreview(app)
        XCTAssertTrue(web.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Front matter'")).firstMatch.waitForExistence(timeout: 10),
                      "no front matter in the preview")
        gateShot("5-preview-front-matter")
    }

}
