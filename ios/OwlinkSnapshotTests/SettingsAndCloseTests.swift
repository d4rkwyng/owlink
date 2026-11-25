import XCTest
import UIKit
import CedricCore

/// Settings opens from every way in, with and without Ask Cedric, and the
/// back chevron (Close) takes the editor away whatever it shows over itself
/// (0.5.2 (17), Derek's iPad check). This test bundle has no app or scene,
/// so modal presentations never finish here: the controllers around the
/// editor are stand-ins that report what the app's would (the document
/// browser presenting the editor's navigation controller, a sheet over
/// it). The real round trips are UI tests (OwlinkUITests).
@MainActor
final class SettingsAndCloseTests: XCTestCase {
    /// Stands in for a controller in the presentation chain.
    final class Stand: UIViewController {
        var presented: UIViewController?
        var presenting: UIViewController?
        var dismissing = false
        var forwardTo: UIResponder?
        var dismissCalls = 0
        var presentCalls: [UIViewController] = []
        override func present(_ controller: UIViewController, animated flag: Bool, completion: (() -> Void)? = nil) {
            presentCalls.append(controller)
        }
        override var presentedViewController: UIViewController? { presented }
        override var presentingViewController: UIViewController? { presenting }
        override var isBeingDismissed: Bool { dismissing }
        override var next: UIResponder? { forwardTo ?? super.next }
        override func dismiss(animated flag: Bool, completion: (() -> Void)? = nil) {
            dismissCalls += 1
            completion?()
        }
    }

    final class StandNav: UINavigationController {
        var presented: UIViewController?
        var presenting: UIViewController?
        override var presentedViewController: UIViewController? { presented }
        override var presentingViewController: UIViewController? { presenting }
    }

    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
    }

    private func editor(readMode: Bool = true) -> (StandNav, EditorViewController) {
        let doc = TextDocument(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md"))
        doc.language.choose(.markdown)
        doc.text = "# Owls\n"
        let editor = EditorViewController(document: doc, readModeOnOpen: readMode)
        let nav = StandNav(rootViewController: editor)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = nav
        window.makeKeyAndVisible()
        windows.append(window)
        return (nav, editor)
    }

    /// A controller whose view is in a window, as a shown sheet's is.
    private func shownSheet() -> Stand {
        let s = Stand()
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        w.addSubview(s.view)
        w.isHidden = false
        windows.append(w)
        return s
    }

    // MARK: Where Settings goes

    func testSettingsGoesOnTheNavigationControllerWithNothingUp() {
        let (nav, editor) = editor()
        XCTAssertTrue(editor.sheetPresenter() === nav)
    }

    /// Ask Cedric up: Settings goes on top of it (the conversation stays).
    func testSettingsGoesOverAskCedric() {
        let (nav, editor) = editor()
        let ask = shownSheet()
        nav.presented = ask
        XCTAssertTrue(editor.sheetPresenter() === ask)
    }

    /// Never on a sheet on its way out, nor on one no longer on screen.
    func testSettingsSkipsAGoingOrDetachedSheet() {
        let (nav, editor) = editor()
        let going = shownSheet()
        going.dismissing = true
        nav.presented = going
        XCTAssertTrue(editor.sheetPresenter() === nav)
        nav.presented = Stand() // its view never in a window
        XCTAssertTrue(editor.sheetPresenter() === nav)
    }

    // MARK: Menu-bar commands (⌘, Settings…, ⌘W Close)

    /// The editor in the app's navigation controller.
    private func editorInNav() -> (EditorNavigationController, EditorViewController) {
        let (_, e) = editor()
        e.navigationController?.setViewControllers([], animated: false)
        return (EditorNavigationController(rootViewController: e), e)
    }

    /// From the editor's navigation controller (where a sheet over the
    /// editor hands its commands on), the commands reach the editor.
    func testMenuCommandsReachTheEditorFromItsNavigationController() {
        let (nav, editor) = editorInNav()
        for action in [#selector(EditorViewController.showSettings), #selector(EditorViewController.closeDocument),
                       #selector(EditorViewController.askCedric)] {
            XCTAssertTrue(nav.target(forAction: action, withSender: nil) as AnyObject? === editor, "\(action)")
        }
    }

    /// From a sheet over the editor (the chain goes sheet → its presenter).
    func testMenuCommandsReachTheEditorFromASheet() {
        let (nav, editor) = editorInNav()
        let sheet = Stand()
        sheet.forwardTo = nav
        XCTAssertTrue(sheet.target(forAction: #selector(EditorViewController.showSettings), withSender: nil) as AnyObject? === editor,
                      "⌘, from Ask Cedric's sheet doesn't reach the editor")
    }

    /// With nothing first responder in the editor: the window's scene
    /// delegate and the browser hand the command to the editor shown.
    func testMenuCommandsReachTheEditorFromTheScene() {
        let (nav, editor) = editorInNav()
        let browser = Stand()
        browser.presented = nav
        let scene = SceneDelegate()
        let window = UIWindow(frame: .zero)
        window.rootViewController = browser
        scene.window = window
        windows.append(window)
        XCTAssertTrue(scene.target(forAction: #selector(EditorViewController.showSettings), withSender: nil) as AnyObject? === editor)
        // No editor up: nothing to route to.
        browser.presented = nil
        XCTAssertFalse(scene.target(forAction: #selector(EditorViewController.showSettings), withSender: nil) is EditorViewController)
    }

    /// ⌘, is Owlink's Settings…: in place of the app menu's own item
    /// when there is one (it opened the system Settings app), ahead of the
    /// system's behavior, and in the menu bar once either way.
    func testCommaSettingsIsOwlinksSettings() {
        func settings(_ all: [MenuBar.Insertion]) -> [(UIKeyCommand, MenuBar.Place)] {
            all.flatMap { i in Self.commands(i.menu).filter { $0.action == #selector(EditorViewController.showSettings) }.map { ($0, i.place) } }
        }
        let withAppMenu = settings(MenuBar.insertions(hasFind: true, hasSpelling: true, hasAppSettings: true))
        XCTAssertEqual(withAppMenu.count, 1)
        XCTAssertEqual(withAppMenu.first?.1, .replacing(.preferences))
        XCTAssertEqual(withAppMenu.first?.0.input, ",")
        XCTAssertEqual(withAppMenu.first?.0.modifierFlags, .command)
        XCTAssertEqual(withAppMenu.first?.0.wantsPriorityOverSystemBehavior, true)
        let without = settings(MenuBar.insertions(hasFind: true, hasSpelling: true, hasAppSettings: false))
        XCTAssertEqual(without.count, 1)
        XCTAssertEqual(without.first?.1, .after(.view))
    }

    /// 0.5.2 (18) gate: ⇧⌘P didn't reach the editor on the iPads. The
    /// shortcuts the system, UIKit, `UITextView` or `WKWebView` can take
    /// ahead of Owlink's (Close Window, zoom, bold / italic, history, …)
    /// claim priority over the system's behavior, with or without the app
    /// menu's Settings…; no advertised shortcut changed (⇧⌘K is still
    /// Delete Line and Ask Cedric…).
    func testContestableShortcutsAreClaimed() {
        let contestable: [(String, UIKeyModifierFlags, String)] = [
            ("w", .command, "⌘W"), ("p", [.command, .shift], "⇧⌘P"), ("p", [.command, .alternate], "⌥⌘P"),
            ("+", .command, "⌘+"), ("=", .command, "⌘="), ("-", .command, "⌘-"), ("0", .command, "⌘0"),
            ("b", .command, "⌘B"), ("i", .command, "⌘I"), ("]", .command, "⌘]"), ("[", .command, "⌘["),
            ("s", .command, "⌘S"), ("l", .command, "⌘L"), ("k", .command, "⌘K"), ("n", [.command, .alternate], "⌥⌘N"),
            ("/", .command, "⌘/"), (",", .command, "⌘,"),
        ]
        for hasAppSettings in [true, false] {
            let all = MenuBar.insertions(hasFind: true, hasSpelling: true, hasAppSettings: hasAppSettings)
                .flatMap { Self.commands($0.menu) }
            for (input, modifiers, name) in contestable {
                let keys = all.filter { $0.input == input && $0.modifierFlags == modifiers }
                XCTAssertFalse(keys.isEmpty, "\(name) isn't in the menu bar (hasAppSettings: \(hasAppSettings))")
                for k in keys {
                    XCTAssertTrue(k.wantsPriorityOverSystemBehavior,
                                  "\(name) (\(k.title)) doesn't claim priority over the system (hasAppSettings: \(hasAppSettings))")
                }
            }
            let shiftK = all.filter { $0.input == "k" && $0.modifierFlags == [.command, .shift] }.compactMap(\.action)
            XCTAssertEqual(Set(shiftK), [#selector(EditorViewController.deleteLine(_:)), #selector(EditorViewController.askCedric)])
        }
    }

    /// 0.5.2 (18) gate: `-OwlinkFreshSample` left an earlier test's
    /// recovery record for the sample (and `copyItem` kept the bundle's
    /// older date, which the record beat), so "Owlink closed with unsaved
    /// changes in README.md. Restore?" covered the next test and held
    /// ⇧⌘P. The fresh sample now clears that document's record (by its
    /// path and its resolved path) and is dated now; other documents'
    /// records stay.
    func testFreshSampleClearsItsRecoveryRecordOnly() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FreshSample-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let bundle = root.appendingPathComponent("Samples", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        let link = root.appendingPathComponent("Linked", isDirectory: true)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: link, withDestinationURL: docs)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let sample = bundle.appendingPathComponent("README.md")
        try Data("# Sample\n".utf8).write(to: sample)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: sample.path)
        // The document as an earlier test left it, reached through the link.
        let url = link.appendingPathComponent("README.md")
        try Data("# Sample\nhoot roundtrip\n".utf8).write(to: docs.appendingPathComponent("README.md"))
        let other = docs.appendingPathComponent("Other.md")
        try Data("other\n".utf8).write(to: other)

        let store = RecoveryStore(directory: root.appendingPathComponent("Recovery", isDirectory: true))
        func record(_ path: String) -> RecoveryRecord {
            RecoveryRecord(documentPath: path, displayName: (path as NSString).lastPathComponent, bookmark: nil,
                           savedAt: old.addingTimeInterval(60), text: "unsaved", encoding: .utf8, lineEnding: .lf)
        }
        let path = url.standardizedFileURL.path
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        XCTAssertNotEqual(path, resolved, "the test's link didn't give the document two paths")
        let otherPath = other.standardizedFileURL.path
        for p in [path, resolved, otherPath] { try store.write(record(p)) }
        XCTAssertNotNil(store.pending(documentPath: path, documentModified: old))

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        TestLaunch.prepareFreshSample(sample, at: url, recovery: store, now: now)

        XCTAssertEqual(try Data(contentsOf: url), Data("# Sample\n".utf8), "the sample wasn't copied fresh")
        let modified = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 1,
                       "the fresh copy kept the bundle sample's date")
        XCTAssertNil(store.read(documentPath: path), "the fresh sample's recovery record is still there")
        XCTAssertNil(store.read(documentPath: resolved), "the fresh sample's recovery record (resolved path) is still there")
        XCTAssertNil(store.pending(documentPath: path, documentModified: modified))
        XCTAssertEqual(store.read(documentPath: otherPath), record(otherPath), "another document's recovery record was cleared")
        XCTAssertEqual(store.all().map(\.documentPath), [otherPath])
    }

    /// Astra / Sol (18): a sample that can't be put in place keeps the
    /// document as it was and its recovery record (the unsaved text is
    /// still offered), and says so: whether the copy fails (no sample) or
    /// the swap fails after the dated copy is staged beside the document.
    /// The document is never removed ahead of the swap, and nothing staged
    /// is left behind.
    func testFreshSampleThatFailsKeepsTheRecoveryRecord() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FreshSampleFail-\(UUID().uuidString)", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let url = docs.appendingPathComponent("README.md")
        defer {
            try? fm.setAttributes([.immutable: false], ofItemAtPath: url.path)
            try? fm.removeItem(at: root)
        }
        let earlier = Data("# Sample\nhoot roundtrip\n".utf8)
        try earlier.write(to: url)
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        let store = RecoveryStore(directory: root.appendingPathComponent("Recovery", isDirectory: true))
        let path = url.standardizedFileURL.path
        let record = RecoveryRecord(documentPath: path, displayName: "README.md", bookmark: nil,
                                    savedAt: old.addingTimeInterval(60), text: "unsaved",
                                    encoding: .utf8, lineEnding: .lf)
        try store.write(record)
        let queue = DispatchQueue(label: "test.fresh-sample")
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        func checkKept(_ when: String, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(store.read(documentPath: path), record, "\(when): the recovery record was cleared", file: file, line: line)
            let modified = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date, file: file, line: line)
            XCTAssertEqual(modified.timeIntervalSince1970, old.timeIntervalSince1970, accuracy: 1,
                           "\(when): the document was redated", file: file, line: line)
            XCTAssertEqual(store.pending(documentPath: path, documentModified: modified), record,
                           "\(when): the unsaved text is no longer offered", file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: url), earlier, "\(when): the document changed", file: file, line: line)
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: docs.path), ["README.md"],
                           "\(when): a staged copy was left behind", file: file, line: line)
        }

        // No sample to copy: fails before anything is staged.
        let missing = root.appendingPathComponent("Samples/README.md")
        XCTAssertFalse(TestLaunch.prepareFreshSample(missing, at: url, recovery: store, queue: queue, now: now))
        try checkKept("no sample")

        // The sample copies and is dated beside the document, but the
        // document can't be swapped out (it's locked): fails after staging.
        let samples = root.appendingPathComponent("Samples", isDirectory: true)
        try fm.createDirectory(at: samples, withIntermediateDirectories: true)
        let sample = samples.appendingPathComponent("README.md")
        try Data("# Sample\n".utf8).write(to: sample)
        try fm.setAttributes([.immutable: true], ofItemAtPath: url.path)
        XCTAssertFalse(TestLaunch.prepareFreshSample(sample, at: url, recovery: store, queue: queue, now: now))
        try fm.setAttributes([.immutable: false], ofItemAtPath: url.path)
        try checkKept("swap refused after staging")
        XCTAssertTrue(fm.fileExists(atPath: sample.path), "the sample itself went")

        // Unlocked, the same call goes through and only then clears it.
        XCTAssertTrue(TestLaunch.prepareFreshSample(sample, at: url, recovery: store, queue: queue, now: now))
        XCTAssertEqual(try Data(contentsOf: url), Data("# Sample\n".utf8))
        XCTAssertNil(store.read(documentPath: path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: docs.path), ["README.md"], "a staged copy was left behind")
    }

    /// Astra / Sol (18): `-OwlinkFreshSample` is acted on once per process,
    /// so a second window (⌥⌘N) doesn't wipe the document under the first.
    /// The real launch path, twice: the first puts the sample in fresh and
    /// clears its record; after an edit (and its unsaved text recorded),
    /// the second opens the edited document and leaves the record offered.
    func testFreshSampleIsClaimedOncePerProcess() throws {
        TestLaunch.resetFreshSampleClaim()
        defer { TestLaunch.resetFreshSampleClaim() }
        XCTAssertFalse(TestLaunch.claimFreshSample(requested: false))
        XCTAssertFalse(TestLaunch.freshSampleConsumed, "a launch without the flag used up the claim")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("FreshSampleOnce-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let bundleURL = root.appendingPathComponent("Fixture.bundle", isDirectory: true)
        let samples = bundleURL.appendingPathComponent("Samples", isDirectory: true)
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: samples, withIntermediateDirectories: true)
        try fm.createDirectory(at: docs, withIntermediateDirectories: true)
        let sampleText = Data("# Sample\n".utf8)
        try sampleText.write(to: samples.appendingPathComponent("README.md"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))
        let store = RecoveryStore(directory: root.appendingPathComponent("Recovery", isDirectory: true))
        let url = docs.appendingPathComponent("README.md")
        let path = url.standardizedFileURL.path
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func record(_ savedAt: Date) -> RecoveryRecord {
            RecoveryRecord(documentPath: path, displayName: "README.md", bookmark: nil,
                           savedAt: savedAt, text: "unsaved", encoding: .utf8, lineEnding: .lf)
        }
        // An earlier test's leftovers.
        try Data("# Sample\nhoot roundtrip\n".utf8).write(to: url)
        try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        try store.write(record(old.addingTimeInterval(60)))
        let args = ["Owlink", "-OwlinkOpen", "README.md", "-OwlinkFreshSample"]
        func launch() -> URL? {
            TestLaunch.documentToOpen(arguments: args, documentsDirectory: docs, bundle: bundle,
                                      recovery: store, queue: nil, now: now)
        }

        // Launch 1 (the first window).
        XCTAssertEqual(launch()?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertTrue(TestLaunch.freshSampleConsumed)
        XCTAssertEqual(try Data(contentsOf: url), sampleText, "launch 1 didn't put the sample in fresh")
        XCTAssertNil(store.read(documentPath: path), "launch 1 left the earlier recovery record")

        // An edit in the first window, saved, then more typed and recorded.
        let edited = Data("# Sample\nedited in window 1\n".utf8)
        try edited.write(to: url)
        let editedAt = now.addingTimeInterval(30)
        try fm.setAttributes([.modificationDate: editedAt], ofItemAtPath: url.path)
        let unsaved = record(editedAt.addingTimeInterval(30))
        try store.write(unsaved)

        // Launch 2 (⌥⌘N), same arguments, same process.
        XCTAssertEqual(launch()?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(try Data(contentsOf: url), edited, "a second window put the sample over the edited document")
        let modified = try XCTUnwrap(fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)
        XCTAssertEqual(modified.timeIntervalSince1970, editedAt.timeIntervalSince1970, accuracy: 1,
                       "a second window redated the document")
        XCTAssertEqual(store.pending(documentPath: path, documentModified: modified), unsaved,
                       "a second window cleared the first's recovery record")
        XCTAssertFalse(TestLaunch.claimFreshSample(requested: true), "the claim came back")
    }

    /// Astra / Sol (18): ⌘B, ⌘] and ⌘/ claim priority over the system's
    /// keys, so with the Find field (a field in the editor's window) or
    /// Ask Cedric's field (in its sheet's window) taking the typing they'd
    /// change the document behind it. They're off while it has the
    /// keyboard and back once it lets go; ⌘, ⌘W ⌘S and ⇧⌘P stay on.
    func testDocumentEditsStayOffWhileAnotherFieldHasTheKeyboard() throws {
        let (nav, editor) = editor(readMode: false)
        let edits = [#selector(EditorViewController.markdownBoldMenu(_:)), #selector(EditorViewController.indentLines(_:)),
                     #selector(EditorViewController.commentSelection(_:))]
        let kept = [#selector(EditorViewController.showSettings), #selector(EditorViewController.closeDocument),
                    #selector(EditorViewController.saveDocument), #selector(EditorViewController.togglePreview)]
        func check(_ editsOn: Bool, _ when: String, file: StaticString = #filePath, line: UInt = #line) {
            for action in edits {
                XCTAssertEqual(editor.canPerformAction(action, withSender: nil), editsOn, "\(action) \(when)", file: file, line: line)
            }
            for action in kept {
                XCTAssertTrue(editor.canPerformAction(action, withSender: nil), "\(action) \(when)", file: file, line: line)
            }
        }
        check(true, "with nothing else focused")
        XCTAssertTrue(editor.textView.becomeFirstResponder())
        XCTAssertFalse(editor.otherTextInputHasFocus, "the editor's own text view counted as another field")
        check(true, "with the text focused")

        // The Find field: in the editor's window.
        let window = try XCTUnwrap(editor.view.window)
        let find = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        window.addSubview(find)
        XCTAssertTrue(find.becomeFirstResponder())
        check(false, "with the Find field focused")
        XCTAssertTrue(find.resignFirstResponder())
        check(true, "after the Find field let go")
        find.removeFromSuperview()

        // Ask Cedric's field: in its sheet's own window here.
        let ask = askSheet()
        nav.presented = ask
        let field = UITextField(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        ask.view.addSubview(field)
        field.window?.makeKey()
        XCTAssertTrue(field.becomeFirstResponder())
        check(false, "with Ask Cedric's field focused")
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.askCedric), withSender: nil))
        XCTAssertTrue(field.resignFirstResponder())
        check(true, "after Ask Cedric's field let go")
        nav.presented = nil
        field.removeFromSuperview()

        // A text view that isn't the editor's (a sheet's notes, say).
        window.makeKey()
        let other = UITextView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))
        window.addSubview(other)
        XCTAssertTrue(other.becomeFirstResponder())
        XCTAssertTrue(editor.otherTextInputHasFocus, "another text view didn't count")
        check(false, "with another text view focused")
        XCTAssertTrue(other.resignFirstResponder())
        check(true, "after the other text view let go")
        other.removeFromSuperview()

        // Clear Bookmarks: on with a bookmark, off while another field
        // has the keyboard, back after.
        let clear = #selector(EditorViewController.clearBookmarksMenu(_:))
        XCTAssertTrue(editor.textView.becomeFirstResponder())
        editor.toggleBookmarkMenu(nil)
        XCTAssertFalse(editor.bookmarks.isEmpty, "the bookmark wasn't added")
        XCTAssertTrue(editor.canPerformAction(clear, withSender: nil), "Clear Bookmarks off with a bookmark")
        for input in [UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30)),
                      UITextView(frame: CGRect(x: 0, y: 0, width: 100, height: 60))] as [UIView] {
            window.addSubview(input)
            XCTAssertTrue(input.becomeFirstResponder())
            XCTAssertFalse(editor.canPerformAction(clear, withSender: nil), "Clear Bookmarks on with \(type(of: input)) focused")
            XCTAssertTrue(input.resignFirstResponder())
            XCTAssertTrue(editor.canPerformAction(clear, withSender: nil), "Clear Bookmarks off after \(type(of: input)) let go")
            input.removeFromSuperview()
        }

        // The preview (a web view) doesn't count: edits, preview, Go to
        // Line and zoom all stay on with it shown and focused.
        let preserved = [#selector(EditorViewController.togglePreview), #selector(EditorViewController.toggleFocusPreview),
                         #selector(EditorViewController.goToLine), #selector(EditorViewController.biggerFont),
                         #selector(EditorViewController.smallerFont), #selector(EditorViewController.actualSizeFont)]
        func checkPreserved(_ when: String, file: StaticString = #filePath, line: UInt = #line) {
            for action in preserved {
                XCTAssertTrue(editor.canPerformAction(action, withSender: nil), "\(action) \(when)", file: file, line: line)
            }
        }
        checkPreserved("with the text focused")
        editor.togglePreview()
        let web = try XCTUnwrap(editor.preview?.web, "the preview has no web view")
        XCTAssertNotNil(web.window, "the preview's web view isn't in the window")
        _ = web.becomeFirstResponder()
        XCTAssertFalse(editor.otherTextInputHasFocus, "the preview counted as another field")
        check(true, "with the preview shown")
        checkPreserved("with the preview shown")
        XCTAssertTrue(editor.canPerformAction(clear, withSender: nil), "Clear Bookmarks off with the preview shown")

        // …and with another field focused while the preview is up, edits
        // go off but the preview, Go to Line and zoom stay.
        let findOverPreview = UITextField(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        window.addSubview(findOverPreview)
        XCTAssertTrue(findOverPreview.becomeFirstResponder())
        check(false, "with the Find field focused over the preview")
        checkPreserved("with the Find field focused over the preview")
        XCTAssertTrue(findOverPreview.resignFirstResponder())
        findOverPreview.removeFromSuperview()
        check(true, "after the Find field let go over the preview")
        editor.togglePreview()
    }

    /// Records what `MenuBar.apply` does to the system's menus.
    @MainActor final class RecordingBuilder: MenuBar.Editing {
        var present: Set<UIMenu.Identifier>
        var replaced: [(UIMenu.Identifier, UIMenu)] = []
        var inserted: [UIMenu] = []
        init(present: Set<UIMenu.Identifier>) { self.present = present }
        func menu(for identifier: UIMenu.Identifier) -> UIMenu? {
            present.contains(identifier) ? UIMenu(title: identifier.rawValue, identifier: identifier, children: []) : nil
        }
        func remove(menu identifier: UIMenu.Identifier) { present.remove(identifier) }
        func insertChild(_ menu: UIMenu, atStartOfMenu identifier: UIMenu.Identifier) { inserted.append(menu) }
        func insertChild(_ menu: UIMenu, atEndOfMenu identifier: UIMenu.Identifier) { inserted.append(menu) }
        func insertSibling(_ menu: UIMenu, afterMenu identifier: UIMenu.Identifier) { inserted.append(menu) }
        func replace(menu identifier: UIMenu.Identifier, with menu: UIMenu) { replaced.append((identifier, menu)) }
        var settingsInserted: [UIKeyCommand] {
            inserted.flatMap { SettingsAndCloseTests.commands($0) }.filter { $0.action == #selector(EditorViewController.showSettings) }
        }
    }

    /// Runs `MenuBar.apply` as at launch, counting the rebuilds it asks for.
    private func applyMenuBar(_ builder: RecordingBuilder, rebuilds: inout Int) {
        var count = 0
        let saved = MenuBar.requestRebuild
        MenuBar.requestRebuild = { _ in count += 1 }
        MenuBar.apply(to: builder)
        MenuBar.requestRebuild = saved
        rebuilds += count
    }

    /// The pending retry's timer fires (UIKit's rebuild recorded, not
    /// done). Returns whether it asked UIKit for a rebuild.
    @discardableResult private func fireRetry() -> Bool {
        var asked = false
        let saved = MenuBar.rebuildMenus
        MenuBar.rebuildMenus = { asked = true }
        MenuBar.firePendingRetryForTesting()
        MenuBar.rebuildMenus = saved
        return asked
    }

    /// 0.5.2 (18): with the app menu's Settings… there, the whole
    /// `.preferences` menu is replaced by Owlink's (not only its children,
    /// which could leave the system's ⌘, to open the system Settings app),
    /// its ⌘, ahead of the system's, and Settings… is not also in the
    /// Cedric menu. No rebuild is needed.
    func testAppMenuSettingsIsReplacedWhole() {
        MenuBar.resetRebuildForTesting()
        defer { MenuBar.resetRebuildForTesting() }
        let builder = RecordingBuilder(present: [.preferences, .find, .spelling, .format])
        var rebuilds = 0
        applyMenuBar(builder, rebuilds: &rebuilds)
        let prefs = builder.replaced.filter { $0.0 == .preferences }
        XCTAssertEqual(prefs.count, 1, "the app menu's Settings… wasn't replaced")
        XCTAssertNotEqual(prefs.first?.1.identifier, .preferences)
        XCTAssertEqual(prefs.first?.1.identifier, MenuBar.settingsMenuIdentifier)
        let keys = prefs.first.map { Self.commands($0.1) } ?? []
        XCTAssertEqual(keys.count, 1)
        XCTAssertEqual(keys.first?.action, #selector(EditorViewController.showSettings))
        XCTAssertEqual(keys.first?.input, ",")
        XCTAssertEqual(keys.first?.modifierFlags, .command)
        XCTAssertEqual(keys.first?.wantsPriorityOverSystemBehavior, true)
        XCTAssertTrue(builder.settingsInserted.isEmpty, "Settings… is in the menu bar twice")
        XCTAssertEqual(rebuilds, 0)
    }

    /// No Settings… in the app menu when the menu is built (the system
    /// adds it later, or never): Settings… goes in the Cedric menu, once,
    /// and the menu is built again, so a `.preferences` the system adds
    /// afterwards is replaced and cannot keep ⌘,. Here the first rebuild
    /// finds it, so that one rebuild is all (more while it is still
    /// missing: testAbsentAppMenuSettingsOnRetryKeepsRebuildingUntilReplaced).
    func testWithoutAppMenuSettingsTheMenuIsBuiltAgainOnce() {
        MenuBar.resetRebuildForTesting()
        defer { MenuBar.resetRebuildForTesting() }
        var rebuilds = 0
        let first = RecordingBuilder(present: [.find, .spelling, .format])
        applyMenuBar(first, rebuilds: &rebuilds)
        XCTAssertTrue(first.replaced.isEmpty)
        XCTAssertEqual(first.settingsInserted.count, 1)
        XCTAssertEqual(first.settingsInserted.first?.input, ",")
        XCTAssertEqual(first.settingsInserted.first?.wantsPriorityOverSystemBehavior, true)
        XCTAssertEqual(rebuilds, 1, "no rebuild asked for without the app menu's Settings…")
        // The rebuild: the system's item is there now, and is replaced.
        let again = RecordingBuilder(present: [.preferences, .find, .spelling, .format])
        applyMenuBar(again, rebuilds: &rebuilds)
        XCTAssertEqual(again.replaced.filter { $0.0 == .preferences }.count, 1)
        XCTAssertTrue(again.settingsInserted.isEmpty)
        // Still none (a system without that item): no endless rebuilds.
        // (The first build's retry is still pending, so this build asks
        // for no other; that retry, when it fires, rebuilds, since this
        // build has no Settings…: testPresentThenAbsentAppMenuSettingsRetriesAgain.)
        applyMenuBar(RecordingBuilder(present: [.find, .spelling]), rebuilds: &rebuilds)
        XCTAssertEqual(rebuilds, 1)
    }

    /// Sol's ordering (0.5.2 (18) review): the first build has no
    /// `.preferences`, nor does the rebuild it asks for. That second build
    /// doesn't give up: it asks for another, and the build that does find
    /// `.preferences` replaces it whole, after which no more are asked for.
    func testAbsentAppMenuSettingsOnRetryKeepsRebuildingUntilReplaced() {
        MenuBar.resetRebuildForTesting()
        defer { MenuBar.resetRebuildForTesting() }
        var rebuilds = 0
        let first = RecordingBuilder(present: [.find, .spelling, .format])
        applyMenuBar(first, rebuilds: &rebuilds)
        XCTAssertTrue(first.replaced.isEmpty)
        XCTAssertEqual(first.settingsInserted.count, 1)
        XCTAssertEqual(rebuilds, 1, "no rebuild asked for without the app menu's Settings…")
        // The retry fires and asks UIKit for the rebuild.
        XCTAssertTrue(fireRetry(), "the pending retry didn't ask for a rebuild")
        // The rebuild: still no Settings… in the app menu.
        let second = RecordingBuilder(present: [.find, .spelling, .format])
        applyMenuBar(second, rebuilds: &rebuilds)
        XCTAssertTrue(second.replaced.isEmpty)
        XCTAssertEqual(second.settingsInserted.count, 1)
        XCTAssertEqual(rebuilds, 2, "gave up after one rebuild that still had no app menu Settings…")
        XCTAssertFalse(MenuBar.appSettingsReplaced)
        // A later build has it: replaced whole, Settings… not also in the Cedric menu.
        let third = RecordingBuilder(present: [.preferences, .find, .spelling, .format])
        applyMenuBar(third, rebuilds: &rebuilds)
        let prefs = third.replaced.filter { $0.0 == .preferences }
        XCTAssertEqual(prefs.count, 1, "the app menu's Settings… wasn't replaced when it came")
        XCTAssertEqual(prefs.first?.1.identifier, MenuBar.settingsMenuIdentifier)
        let keys = prefs.first.map { Self.commands($0.1) } ?? []
        XCTAssertEqual(keys.first?.action, #selector(EditorViewController.showSettings))
        XCTAssertEqual(keys.first?.input, ",")
        XCTAssertEqual(keys.first?.wantsPriorityOverSystemBehavior, true)
        XCTAssertTrue(third.settingsInserted.isEmpty, "Settings… is in the menu bar twice")
        XCTAssertTrue(MenuBar.appSettingsReplaced)
        XCTAssertEqual(rebuilds, 2, "a rebuild was asked for after Settings… was replaced")
        // The retry `second` scheduled is still pending; it fires after
        // the replacement, does nothing, and is gone.
        XCTAssertTrue(MenuBar.retryPendingForTesting)
        XCTAssertFalse(fireRetry(), "the stale retry asked for a rebuild after Settings… was replaced")
        XCTAssertFalse(MenuBar.retryPendingForTesting)
        // Replaced: later builds (with `.preferences` present) and a scene
        // becoming active ask for none.
        let fourth = RecordingBuilder(present: [.preferences, .find, .spelling])
        applyMenuBar(fourth, rebuilds: &rebuilds)
        XCTAssertEqual(fourth.replaced.filter { $0.0 == .preferences }.count, 1)
        XCTAssertTrue(MenuBar.appSettingsReplaced)
        var activations = 0
        let saved = MenuBar.requestRebuild
        MenuBar.requestRebuild = { _ in activations += 1 }
        MenuBar.sceneDidActivate()
        MenuBar.requestRebuild = saved
        XCTAssertEqual(rebuilds, 2)
        XCTAssertFalse(MenuBar.retryPendingForTesting)
        XCTAssertEqual(activations, 0)
    }

    /// A system that never adds the app menu's Settings…: the rebuilds
    /// stop at the cap (no endless loop), each later than the one before
    /// (never only the next main-queue turn), and Settings… stays in the
    /// Cedric menu every time.
    func testRebuildsForAppMenuSettingsStopAtTheCap() {
        MenuBar.resetRebuildForTesting()
        defer { MenuBar.resetRebuildForTesting() }
        var attempts: [Int] = []
        let saved = MenuBar.requestRebuild
        MenuBar.requestRebuild = { attempts.append($0) }
        defer { MenuBar.requestRebuild = saved }
        for _ in 0..<(MenuBar.maxAppSettingsRebuilds + 5) {
            let b = RecordingBuilder(present: [.find, .spelling, .format])
            MenuBar.apply(to: b)
            XCTAssertEqual(b.settingsInserted.count, 1)
            fireRetry() // the next build is the rebuild it asks for
        }
        MenuBar.sceneDidActivate()
        XCTAssertEqual(attempts, Array(1...MenuBar.maxAppSettingsRebuilds))
        XCTAssertFalse(MenuBar.appSettingsReplaced)
        XCTAssertGreaterThan(MenuBar.rebuildDelay(attempt: 1), 0)
        for n in 1..<MenuBar.maxAppSettingsRebuilds {
            XCTAssertLessThanOrEqual(MenuBar.rebuildDelay(attempt: n), MenuBar.rebuildDelay(attempt: n + 1))
        }
        XCTAssertLessThanOrEqual(MenuBar.rebuildDelay(attempt: MenuBar.maxAppSettingsRebuilds), 8)
    }

    /// A scene becoming active before any build found `.preferences` asks
    /// for a rebuild, which replaces it once it is there.
    func testSceneActivationAsksForARebuildUntilAppMenuSettingsIsReplaced() {
        MenuBar.resetRebuildForTesting()
        defer { MenuBar.resetRebuildForTesting() }
        var rebuilds = 0
        applyMenuBar(RecordingBuilder(present: [.find, .spelling, .format]), rebuilds: &rebuilds)
        // Its retry has fired (and its rebuild hasn't come, or still had
        // no Settings…): none is pending when the scene becomes active.
        fireRetry()
        var activations = 0
        let saved = MenuBar.requestRebuild
        MenuBar.requestRebuild = { _ in activations += 1 }
        MenuBar.sceneDidActivate()
        MenuBar.requestRebuild = saved
        XCTAssertEqual(activations, 1, "becoming active didn't ask for a rebuild")
        let later = RecordingBuilder(present: [.preferences, .find, .spelling, .format])
        applyMenuBar(later, rebuilds: &rebuilds)
        XCTAssertEqual(later.replaced.filter { $0.0 == .preferences }.count, 1)
        XCTAssertTrue(MenuBar.appSettingsReplaced)
    }

    /// Astra's hole (0.5.2 (18) review, round 2): replaced once was
    /// recorded for the life of the process, so a later build without
    /// `.preferences` (the Cedric menu's Settings… back, the system's
    /// item gone) never retried, and a system item added after it took
    /// ⌘, again. Now the current build decides: present → absent starts
    /// the retries again, and the late `.preferences` is replaced.
    func testPresentThenAbsentAppMenuSettingsRetriesAgain() {
        MenuBar.resetRebuildForTesting()
        defer { MenuBar.resetRebuildForTesting() }
        var rebuilds = 0
        let present = RecordingBuilder(present: [.preferences, .find, .spelling, .format])
        applyMenuBar(present, rebuilds: &rebuilds)
        XCTAssertEqual(present.replaced.filter { $0.0 == .preferences }.count, 1)
        XCTAssertTrue(MenuBar.appSettingsReplaced)
        XCTAssertEqual(rebuilds, 0)
        XCTAssertFalse(MenuBar.retryPendingForTesting)
        // A later build without it: Settings… in the Cedric menu, and a retry.
        let absent = RecordingBuilder(present: [.find, .spelling, .format])
        applyMenuBar(absent, rebuilds: &rebuilds)
        XCTAssertTrue(absent.replaced.isEmpty)
        XCTAssertEqual(absent.settingsInserted.count, 1)
        XCTAssertFalse(MenuBar.appSettingsReplaced, "replaced stuck from an earlier build")
        XCTAssertEqual(rebuilds, 1, "present → absent didn't start the retries again")
        XCTAssertTrue(fireRetry(), "the retry after present → absent didn't ask for a rebuild")
        XCTAssertEqual(MenuBar.appSettingsRebuilds, 1)
        // Still absent on that rebuild: the next retry.
        applyMenuBar(RecordingBuilder(present: [.find, .spelling, .format]), rebuilds: &rebuilds)
        XCTAssertEqual(rebuilds, 2)
        XCTAssertTrue(fireRetry())
        // The late `.preferences`: replaced whole, nothing more asked for.
        let late = RecordingBuilder(present: [.preferences, .find, .spelling, .format])
        applyMenuBar(late, rebuilds: &rebuilds)
        let prefs = late.replaced.filter { $0.0 == .preferences }
        XCTAssertEqual(prefs.count, 1, "the late app menu Settings… wasn't replaced")
        XCTAssertEqual(prefs.first?.1.identifier, MenuBar.settingsMenuIdentifier)
        XCTAssertTrue(late.settingsInserted.isEmpty, "Settings… is in the menu bar twice")
        XCTAssertTrue(MenuBar.appSettingsReplaced)
        XCTAssertEqual(rebuilds, 2)
        XCTAssertFalse(MenuBar.retryPendingForTesting)
    }

    /// Sol's must-fix (0.5.2 (18) review, round 2): the cap counted
    /// timers queued, so a burst of builds and scene activations queued
    /// overlapping timers and spent the budget at once. Now a burst
    /// before the first timer fires leaves one retry pending; the budget
    /// is spent by retries delivered, one at a time, on the doubling
    /// back-off up to its eight-second plateau; and a retry whose time
    /// comes after `.preferences` was replaced does nothing.
    func testABurstOfBuildsAndActivationsLeavesOneRetryPending() {
        MenuBar.resetRebuildForTesting()
        defer { MenuBar.resetRebuildForTesting() }
        var scheduled: [Int] = []
        let saved = MenuBar.requestRebuild
        MenuBar.requestRebuild = { scheduled.append($0) }
        defer { MenuBar.requestRebuild = saved }
        // The burst, before any timer fires.
        for _ in 0..<5 {
            MenuBar.apply(to: RecordingBuilder(present: [.find, .spelling, .format]))
            MenuBar.sceneDidActivate()
        }
        XCTAssertEqual(scheduled, [1], "overlapping retries were scheduled")
        XCTAssertTrue(MenuBar.retryPendingForTesting)
        XCTAssertEqual(MenuBar.appSettingsRebuilds, 0, "a retry counted before it was delivered")
        // Delivered one at a time: each fire, then its rebuild (and another
        // burst) schedules exactly the next, until the cap.
        for n in 1...MenuBar.maxAppSettingsRebuilds {
            XCTAssertTrue(fireRetry(), "retry \(n) didn't ask for a rebuild")
            XCTAssertEqual(MenuBar.appSettingsRebuilds, n)
            XCTAssertFalse(MenuBar.retryPendingForTesting)
            for _ in 0..<3 {
                MenuBar.apply(to: RecordingBuilder(present: [.find, .spelling, .format]))
                MenuBar.sceneDidActivate()
            }
        }
        XCTAssertEqual(scheduled, Array(1...MenuBar.maxAppSettingsRebuilds))
        XCTAssertFalse(MenuBar.retryPendingForTesting, "a retry past the cap")
        XCTAssertFalse(fireRetry())
        // The back-off: a quarter second, doubling, then eight seconds.
        XCTAssertEqual(scheduled.map { MenuBar.rebuildDelay(attempt: $0) },
                       [0.25, 0.5, 1, 2, 4, 8, 8, 8, 8, 8, 8, 8])
        XCTAssertEqual(MenuBar.rebuildDelay(attempt: 40), 8)
    }

    /// A retry pending when a build replaces `.preferences` does nothing
    /// when its time comes: no rebuild, not counted.
    func testARetryAfterReplacementDoesNotRebuild() {
        MenuBar.resetRebuildForTesting()
        defer { MenuBar.resetRebuildForTesting() }
        var rebuilds = 0
        applyMenuBar(RecordingBuilder(present: [.find, .spelling, .format]), rebuilds: &rebuilds)
        XCTAssertEqual(rebuilds, 1)
        XCTAssertTrue(MenuBar.retryPendingForTesting)
        // Another build (the system's own) finds and replaces it first.
        applyMenuBar(RecordingBuilder(present: [.preferences, .find, .spelling, .format]), rebuilds: &rebuilds)
        XCTAssertTrue(MenuBar.appSettingsReplaced)
        XCTAssertFalse(fireRetry(), "a retry after replacement asked for a rebuild")
        XCTAssertEqual(MenuBar.appSettingsRebuilds, 0, "a skipped retry was counted")
        XCTAssertFalse(MenuBar.retryPendingForTesting)
        XCTAssertEqual(rebuilds, 1)
        MenuBar.sceneDidActivate()
        XCTAssertFalse(MenuBar.retryPendingForTesting, "becoming active scheduled a retry with Settings… replaced")
    }

    /// ⌘, is also on the responders that stay in the chain whatever holds
    /// the keys: the editor's navigation controller and Ask Cedric's sheet
    /// (whose commands go on to it). Untitled, so it is not listed a second
    /// time, and ahead of the system's ⌘, (the system Settings app).
    func testCommaIsClaimedOnTheNavigationControllerAndAskSheet() {
        let (nav, editor) = editorInNav()
        func settingsKeys(_ r: UIResponder) -> [UIKeyCommand] {
            (r.keyCommands ?? []).filter { $0.input == "," && $0.modifierFlags == .command }
        }
        for (name, r) in [("navigation controller", nav as UIResponder), ("Ask Cedric's sheet", askSheet() as UIResponder)] {
            let keys = settingsKeys(r)
            XCTAssertEqual(keys.count, 1, "\(name): no ⌘,")
            XCTAssertEqual(keys.first?.action, #selector(EditorViewController.showSettings), name)
            XCTAssertEqual(keys.first?.wantsPriorityOverSystemBehavior, true, name)
            XCTAssertEqual(keys.first?.title, "", name)
        }
        XCTAssertTrue(nav.target(forAction: #selector(EditorViewController.showSettings), withSender: nil) as AnyObject? === editor)
    }

    static func commands(_ menu: UIMenu) -> [UIKeyCommand] {
        menu.children.flatMap { e -> [UIKeyCommand] in
            if let m = e as? UIMenu { return commands(m) }
            return (e as? UIKeyCommand).map { [$0] } ?? []
        }
    }

    // MARK: Commands over a modal (Codex review of 0.5.2 (17), must-fix 1)

    typealias Routing = EditorCommandRouting

    /// The policy: everything with nothing up or over Ask Cedric; over
    /// another sheet only Settings, Close and Save; over an alert nothing.
    func testWhatAModalLeavesAvailable() {
        let goToLine = #selector(EditorViewController.goToLine)
        let settings = #selector(EditorViewController.showSettings)
        let close = #selector(EditorViewController.closeDocument)
        let save = #selector(EditorViewController.saveDocument)
        let ask = #selector(EditorViewController.askCedric)
        for action in [goToLine, settings, close, save, ask] {
            XCTAssertTrue(Routing.allows(action, over: .none), "\(action)")
            XCTAssertTrue(Routing.allows(action, over: .askCedric), "\(action)")
            XCTAssertFalse(Routing.allows(action, over: .alert), "\(action)")
        }
        XCTAssertFalse(Routing.allows(goToLine, over: .sheet))
        XCTAssertFalse(Routing.allows(ask, over: .sheet))
        for action in [settings, close, save] { XCTAssertTrue(Routing.allows(action, over: .sheet), "\(action)") }
    }

    /// What is over the editor: the topmost live controller decides.
    func testTheModalOverTheEditor() {
        let (nav, _) = editor()
        XCTAssertEqual(Routing.modal(over: nav), .none)
        let settings = shownSheet()
        nav.presented = settings
        XCTAssertEqual(Routing.modal(over: nav), .sheet)
        let alert = UIAlertController(title: "Go to Line", message: nil, preferredStyle: .alert)
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        w.addSubview(alert.view)
        w.isHidden = false
        windows.append(w)
        settings.presented = alert
        XCTAssertEqual(Routing.modal(over: nav), .alert)
        settings.presented = nil
        nav.presented = askSheet()
        XCTAssertEqual(Routing.modal(over: nav), .askCedric)
        // On its way out: not over the editor any more.
        let going = shownSheet()
        going.dismissing = true
        nav.presented = going
        XCTAssertEqual(Routing.modal(over: nav), .none)
    }

    private func askSheet() -> AskSheetHost {
        let host = AskSheetHost(rootView: AskCedricView(model: AskCedricModel(fileName: "README.md", language: .markdown)))
        let w = UIWindow(frame: CGRect(x: 0, y: 0, width: 10, height: 10))
        w.addSubview(host.view)
        w.isHidden = false
        windows.append(w)
        return host
    }

    /// The editor applies the policy itself, so the navigation controller,
    /// browser and scene (which ask it) apply it too: ⌘L is off over
    /// Settings and an alert, on over Ask Cedric; ⌘, and ⌘W stay on over a
    /// sheet.
    func testTheEditorAppliesThePolicy() {
        let (nav, editor) = editor()
        let goToLine = #selector(EditorViewController.goToLine)
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.showStatistics), withSender: nil))
        nav.presented = askSheet()
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.showStatistics), withSender: nil))
        nav.presented = shownSheet()
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.showStatistics), withSender: nil))
        XCTAssertFalse(editor.canPerformAction(goToLine, withSender: nil))
        XCTAssertFalse(editor.canPerformAction(#selector(EditorViewController.askCedric), withSender: nil))
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.showSettings), withSender: nil))
        XCTAssertTrue(editor.canPerformAction(#selector(EditorViewController.closeDocument), withSender: nil))
    }

    /// What the editor presents goes on top of the sheet it shows (Go to
    /// Line over Ask Cedric was refused: the navigation controller was
    /// already presenting).
    func testTheEditorPresentsOnTopOfASheet() {
        let (nav, editor) = editor()
        let sheet = shownSheet()
        nav.presented = sheet
        editor.goToLine()
        XCTAssertEqual(sheet.presentCalls.count, 1)
        XCTAssertTrue(sheet.presentCalls.first is UIAlertController)
    }

    /// Opening Ask Cedric again keeps the open conversation.
    func testAskCedricOpensOnce() {
        let (_, editor) = editor()
        editor.askCedric()
        let first = editor.askModel
        XCTAssertNotNil(first)
        XCTAssertTrue(editor.askIsOpen)
        editor.askCedric()
        XCTAssertTrue(editor.askModel === first, "a second Ask Cedric replaced the open conversation")
    }

    // MARK: Close

    /// Close dismisses from the controller that presented the editor (the
    /// browser): the editor goes with any sheet over it. Dismissing the
    /// editor itself only took the sheet away.
    func testCloseDismissesFromTheBrowser() async throws {
        let (nav, editor) = editor()
        let browser = Stand()
        nav.presenting = browser
        nav.presented = shownSheet()
        let done = expectation(description: "dismissed")
        editor.dismissEditor { done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(browser.dismissCalls, 1)
    }
}
