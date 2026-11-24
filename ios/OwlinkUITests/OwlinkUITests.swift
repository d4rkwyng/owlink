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
        app.buttons["editor.preview"].tap()
        XCTAssertTrue(app.webViews["editor.previewWeb"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.webViews.staticTexts["Owlink for iPhone and iPad"].waitForExistence(timeout: 10))
    }

    /// A web link in the preview asks first (Mac 0.5.2 S1): the tap itself
    /// brings up the prompt, which names the site on its own line and then
    /// shows the whole address; the page never loads in the preview and
    /// there is no Open in Browser button any more. The prompt is captured
    /// as a screenshot attachment and then cancelled (never opened).
    func testWebLinkOpenInBrowserAsksFirst() throws {
        let app = launch("links.md", fresh: true)
        _ = editor(app)
        let web = app.webViews["editor.previewWeb"]
        if !web.waitForExistence(timeout: 2) {
            // In the bar, or (a narrow iPhone) in the system overflow menu.
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
}
