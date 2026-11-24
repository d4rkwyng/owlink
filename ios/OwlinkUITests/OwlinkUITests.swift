import XCTest

/// Drives the real app in the simulator: open a sample, edit, save, reopen;
/// Cedric's offline hint and its fix; the Markdown preview; find.
/// `-OwlinkOpen <name>` opens Documents/<name> (copied from the bundled
/// samples), skipping the document browser.
final class OwlinkUITests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ name: String, fresh: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-OwlinkOpen", name, "-OwlinkResetSettings"] + (fresh ? ["-OwlinkFreshSample"] : [])
        app.launch()
        return app
    }

    private func editor(_ app: XCUIApplication) -> XCUIElement {
        let tv = app.textViews["editor.text"]
        XCTAssertTrue(tv.waitForExistence(timeout: 15), "editor didn't open")
        return tv
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

    func testOpenEditSaveReopen() throws {
        var app = launch("sample.swift", fresh: true)
        var tv = editor(app)
        XCTAssertTrue((tv.value as? String ?? "").contains("struct Owl"))
        XCTAssertTrue(app.buttons["editor.language"].label.contains("Swift"))
        // Opened read-only on iPhone (the default): Edit first.
        let edit = app.buttons["editor.edit"]
        if edit.exists, edit.label == "Edit" { edit.tap() }
        tv.tap()
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
        tv.tap()
        XCTAssertTrue(hide.waitForExistence(timeout: 5), "no hide-keyboard button while editing")
        XCTAssertEqual(hide.label, "Hide Keyboard")
        hide.tap()
        let gone = NSPredicate { _, _ in !app.keyboards.firstMatch.exists }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 5)
    }

    func testOwlHintFixesTrailingSpaces() throws {
        let app = launch("sample.swift", fresh: true)
        let tv = editor(app)
        XCTAssertTrue((tv.value as? String ?? "").contains("struct Owl {   "))
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

    func testFindNavigatorOpens() throws {
        let app = launch("sample.swift", fresh: true)
        _ = editor(app)
        app.buttons["editor.find"].tap()
        let field = app.textFields.matching(NSPredicate(format: "placeholderValue CONTAINS[c] 'Search' OR placeholderValue CONTAINS[c] 'Find'")).firstMatch
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
        preview.tap()
        let focus = app.collectionViews.buttons.matching(NSPredicate(format: "label == %@", "Focus Preview"))
        XCTAssertTrue(focus.firstMatch.waitForExistence(timeout: 5), "no Focus Preview in the Preview submenu")
        XCTAssertEqual(focus.count, 1, "Focus Preview more than once in the Preview submenu")
        shoot("menu-preview-submenu")
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

    /// An item of the open ••• menu, scrolled to (the menu is long).
    private func menuItem(_ app: XCUIApplication, _ label: String) -> XCUIElement {
        let item = app.collectionViews.buttons[label].firstMatch
        // Down the menu, then back up if a swipe went past it.
        for i in 0..<14 {
            if item.waitForExistence(timeout: 1), item.isHittable { return item }
            let list = app.collectionViews.firstMatch
            guard list.exists else { break }
            if i < 7 { list.swipeUp(velocity: .slow) } else { list.swipeDown(velocity: .slow) }
        }
        XCTAssertTrue(item.exists && item.isHittable, "no \(label) in the ••• menu")
        return item
    }

    /// Closes an open menu by tapping outside it (on the status line).
    private func closeMenu(_ app: XCUIApplication) {
        app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)).tap()
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
        let popOut = app.buttons["ask.popOut"].firstMatch
        if sheet, popOut.exists {
            popOut.tap()
            sleep(1)
        }
        XCTAssertTrue(done.waitForExistence(timeout: 5))
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

    /// The sheet stops at half height, undimmed: the back chevron stays
    /// tappable over it. It closes the document (sheet and all), and is
    /// never left dead.
    func testBackChevronWithAskCedricOpen() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        openAsk(app, sheet: true)
        let back = app.navigationBars.buttons["BackButton"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        // A tap where the chevron is (XCUITest may count the undimmed
        // sheet's container as covering it; a finger isn't stopped by it).
        back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        if !app.descendants(matching: .any)["browser.settings"].waitForExistence(timeout: 6), back.exists {
            back.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap() // the second tap a person would try
        }
        XCTAssertTrue(app.descendants(matching: .any)["browser.settings"].waitForExistence(timeout: 10),
                      "Ask Cedric open: the back chevron didn't return to the file list")
        XCTAssertFalse(app.textViews["editor.text"].exists, "the editor is still open")
    }

    /// Settings opened over the Ask Cedric sheet (iPhone: from the •••
    /// menu above it), closed, Ask Cedric closed, then the back chevron.
    func testSettingsOverAskCedricThenBack() throws {
        let app = launch("README.md", fresh: true)
        _ = editor(app)
        if device == "ipad" { throw XCTSkip("the iPad's Ask Cedric is docked: testSettingsOpensWithCedricOpen") }
        openAsk(app, sheet: true)
        let more = app.navigationBars.buttons["More"].firstMatch
        guard more.exists else { throw XCTSkip("••• covered by the sheet") }
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

    /// Editing with the keyboard (and so the format bar) up. The iPad
    /// simulator with its hardware keyboard shows no input accessory at
    /// all (before Ask Cedric too): nothing to check there.
    private func startTyping(_ app: XCUIApplication, _ tv: XCUIElement) throws {
        let edit = app.buttons["editor.edit"]
        if edit.exists, edit.label == "Edit" { edit.tap() }
        tv.tap()
        if !formatBar(app).waitForExistence(timeout: 8), device == "ipad" {
            throw XCTSkip("no format bar on screen while editing (hardware keyboard, no input accessory shown)")
        }
        XCTAssertTrue(formatBar(app).exists, "no format bar while editing Markdown")
    }

    private func waitGone(_ e: XCUIElement, _ message: String) {
        let gone = NSPredicate { _, _ in !e.exists || !e.isHittable }
        wait(for: [XCTNSPredicateExpectation(predicate: gone, object: nil)], timeout: 8)
        XCTAssertFalse(e.exists && e.isHittable, message)
    }

    func testFormatBarHiddenUnderAskCedric() throws {
        let app = launch("README.md", fresh: true)
        let tv = editor(app)
        try startTyping(app, tv)
        openAsk(app, sheet: true)
        waitGone(formatBar(app), "the format bar shows under Ask Cedric")
        shoot("ask-cedric-no-format-bar")
        closeAskWithDone(app)
        tv.tap()
        XCTAssertTrue(formatBar(app).waitForExistence(timeout: 8), "the format bar didn't come back after Done")
        shoot("format-bar-restored")
        // And after a swipe down.
        openAsk(app, sheet: true)
        waitGone(formatBar(app), "the format bar shows under Ask Cedric (again)")
        closeAskBySwipe(app)
        tv.tap()
        XCTAssertTrue(formatBar(app).waitForExistence(timeout: 8), "the format bar didn't come back after a swipe down")
    }

}
