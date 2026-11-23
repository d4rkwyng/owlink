import XCTest
import UIKit
import CedricCore

/// A checker that flags a fixed set of words (the system's depends on the
/// simulator's languages); Learn Word only records the word.
@MainActor
private final class FakeChecker: SpellStepChecking {
    var words: Set<String>
    var suggestions: [String: [String]]
    private(set) var ignored: [String] = []
    private(set) var learned: [String] = []
    private(set) var checkedLength = 0

    init(_ suggestions: [String: [String]]) {
        self.suggestions = suggestions
        words = Set(suggestions.keys)
    }

    func misspellings(in text: String) -> [NSRange] {
        let ns = text as NSString
        checkedLength += ns.length
        var out: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { w, r, _, _ in
            if let w, self.words.contains(w) { out.append(r) }
        }
        return out
    }

    func guesses(for word: String) -> [String] { suggestions[word] ?? [] }
    func ignore(_ word: String) { ignored.append(word); words.remove(word) }
    func learn(_ word: String) { learned.append(word); words.remove(word) }
}

/// Fix Typos… (iPad Edit › Spelling and Grammar, ⌥⌘; and the editor
/// menu): the Mac's step-through over the shared SpellStepper.
@MainActor
final class FixTyposTests: XCTestCase {
    private var windows: [UIWindow] = []
    private var oldSpelling: Any?
    private var learnedForReal: [String] = []

    override func setUp() async throws {
        oldSpelling = AppSettings.defaults.object(forKey: AppSettings.Key.checkSpellingWhileTyping)
    }

    override func tearDown() async throws {
        for w in learnedForReal { UITextChecker.unlearnWord(w) }
        learnedForReal = []
        for window in windows { window.isHidden = true; window.rootViewController = nil }
        windows = []
        if let oldSpelling {
            AppSettings.defaults.set(oldSpelling, forKey: AppSettings.Key.checkSpellingWhileTyping)
        } else {
            AppSettings.defaults.removeObject(forKey: AppSettings.Key.checkSpellingWhileTyping)
        }
    }

    private func editor(_ text: String, fileName: String = "notes.md", language: Language? = nil) -> EditorViewController {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(fileName)
        let doc = TextDocument(fileURL: url)
        doc.text = text
        doc.language = .forFile(named: fileName, content: text)
        if let language { doc.language.choose(language) }
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        editor.textView.selectedRange = NSRange(location: 0, length: 0)
        return editor
    }

    private func settle(_ t: TimeInterval = 0.05) { RunLoop.main.run(until: Date().addingTimeInterval(t)) }

    private func find(_ id: String, in elements: [UIMenuElement]) -> UIAction? {
        for e in elements {
            if let a = e as? UIAction, a.accessibilityIdentifier == id { return a }
            if let m = e as? UIMenu, let a = find(id, in: m.children) { return a }
        }
        return nil
    }

    private var fixTypos: Selector { #selector(EditorViewController.fixTypos) }

    // MARK: Which documents

    func testOfferedForProseAndCodeNotData() throws {
        for (name, language) in [("notes.md", Language?.none), ("notes.txt", nil), ("main.swift", nil)] {
            let e = editor("Some text.\n", fileName: name, language: language)
            let item = try XCTUnwrap(find("editor.menu.fixTypos", in: e.moreMenuItems()), name)
            XCTAssertFalse(item.attributes.contains(.disabled), name)
            XCTAssertEqual(item.title, "Fix Typos…")
            XCTAssertTrue(e.canPerformAction(fixTypos, withSender: nil), name)
        }
        for (name, language) in [("config.json", Language?.none), ("table.csv", .plain), ("cert.pem", .plain)] {
            let e = editor("{\"name\": \"valeu\"}\n", fileName: name, language: language)
            let item = try XCTUnwrap(find("editor.menu.fixTypos", in: e.moreMenuItems()), name)
            XCTAssertTrue(item.attributes.contains(.disabled), name)
            XCTAssertFalse(e.canPerformAction(fixTypos, withSender: nil), name)
        }
    }

    func testDataFileDoesNotStartAPass() {
        let e = editor("name,value\nfoo,valeu\n", fileName: "table.csv", language: .plain)
        let checker = FakeChecker(["valeu": ["value"]])
        XCTAssertNil(e.startFixTypos(checker: checker))
        XCTAssertNil(e.spellStep)
        XCTAssertEqual(checker.checkedLength, 0)
    }

    // MARK: Stepping

    func testStepThroughChangeSkipIgnoreDone() throws {
        let text = "Teh first wrod.\nAnother wrod and a zorb.\nThe last zorb.\n"
        let e = editor(text)
        let checker = FakeChecker(["Teh": ["The", "Tech"], "wrod": ["word"], "zorb": ["orb"]])
        let s = try XCTUnwrap(e.startFixTypos(checker: checker))
        XCTAssertTrue(s.card.superview === e.view)
        XCTAssertTrue(s.card.isFirstResponder)
        XCTAssertEqual(s.current?.word, "Teh")
        XCTAssertEqual(e.textView.selectedRange, NSRange(location: 0, length: 3))
        XCTAssertEqual(s.card.guesses, ["The", "Tech"])
        XCTAssertEqual(s.selectedGuess, "The")
        XCTAssertTrue(s.card.changeButton.isEnabled)
        XCTAssertEqual(s.card.wordLabel.text, "“Teh”")
        settle()
        XCTAssertEqual(s.card.progressLabel.text, "1 of 5")

        // Change: one undo step.
        let um = try XCTUnwrap(e.textView.undoManager)
        s.change()
        XCTAssertTrue(e.textView.text.hasPrefix("The first wrod."))
        XCTAssertTrue(um.canUndo)
        XCTAssertEqual(s.current?.word, "wrod")
        XCTAssertEqual((e.textView.text as NSString).substring(with: e.textView.selectedRange), "wrod")
        XCTAssertEqual(s.card.progressLabel.text, "2 of 5")

        // Skip moves on to the next one.
        s.skip()
        XCTAssertEqual(s.current?.word, "wrod")
        XCTAssertEqual(s.current?.range.location, (e.textView.text as NSString).range(of: "Another wrod").location + 8)

        // Ignore All: the word isn't shown again.
        s.ignoreAll()
        XCTAssertEqual(s.current?.word, "zorb")
        XCTAssertEqual(checker.ignored, ["wrod"])
        s.ignoreAll()
        XCTAssertNil(s.current)
        XCTAssertTrue(s.stepper.isFinished)
        XCTAssertEqual(s.card.wordLabel.text, "No more typos. Changed 1.")

        // Undo puts the first word back.
        um.undo()
        XCTAssertTrue(e.textView.text.hasPrefix("Teh first wrod."))

        s.done()
        XCTAssertNil(s.card.superview)
        XCTAssertNil(e.spellStep)
        XCTAssertFalse(s.isOpen)
    }

    func testChangeAllIsOneUndoGroup() throws {
        let text = "One recieve here.\nTwo recieve there.\n"
        let e = editor(text)
        let s = try XCTUnwrap(e.startFixTypos(checker: FakeChecker(["recieve": ["receive"]])))
        XCTAssertEqual(s.current?.word, "recieve")
        let um = try XCTUnwrap(e.textView.undoManager)
        s.changeAll()
        XCTAssertEqual(e.textView.text, "One receive here.\nTwo receive there.\n")
        XCTAssertTrue(s.stepper.isFinished)
        um.undo()
        XCTAssertEqual(e.textView.text, text)
        XCTAssertFalse(um.canUndo)
        s.done()
    }

    func testLearnWordAndStartingAgainBringsTheSameCardForward() throws {
        let e = editor("A zorb and a zorb and a wrod.\n")
        let checker = FakeChecker(["zorb": [], "wrod": ["word"]])
        let s = try XCTUnwrap(e.startFixTypos(checker: checker))
        XCTAssertEqual(s.current?.word, "zorb")
        // No suggestion: nothing to change to.
        XCTAssertFalse(s.card.changeButton.isEnabled)
        XCTAssertTrue(s.card.learnButton.isEnabled)
        e.textView.becomeFirstResponder()
        XCTAssertTrue(e.startFixTypos(checker: FakeChecker([:])) === s)
        XCTAssertTrue(s.card.isFirstResponder)
        XCTAssertEqual(e.view.subviews.filter { $0 is SpellStepCard }.count, 1)
        s.learn()
        XCTAssertEqual(checker.learned, ["zorb"])
        XCTAssertEqual(s.current?.word, "wrod")
        s.done()
    }

    func testScopeSkipsCodeAndLinksInMarkdownAndIdentifiersInCode() throws {
        let md = editor("A wrod here, `wrod` there, [wrod](https://x.example/wrod) and http://wrod.example.\n")
        let s = try XCTUnwrap(md.startFixTypos(checker: FakeChecker(["wrod": ["word"]])))
        settle()
        XCTAssertEqual(s.current?.range.location, 2)
        s.skip()
        XCTAssertTrue(s.stepper.isFinished, "only the prose word")
        s.done()

        let swift = editor("// A wrod in a comment\nlet wrod = \"wrod\"\n", fileName: "main.swift")
        let c = try XCTUnwrap(swift.startFixTypos(checker: FakeChecker(["wrod": ["word"]])))
        settle()
        XCTAssertEqual(c.stepper.progress.total, 2, "the comment and the string, not the identifier")
        c.done()
    }

    // MARK: Not modal

    func testTypingMovesAndDropsPendingWords() throws {
        let e = editor("Teh one wrod.\nA zorb.\n")
        let s = try XCTUnwrap(e.startFixTypos(checker: FakeChecker(["Teh": ["The"], "wrod": ["word"], "zorb": ["orb"]])))
        settle()
        XCTAssertEqual(s.current?.word, "Teh")
        // The user types before the pending words: they move.
        e.textView.textStorage.replaceCharacters(in: NSRange(location: 4, length: 0), with: "more ")
        let wrodAt = (e.textView.text as NSString).range(of: "wrod")
        XCTAssertEqual(s.stepper.pending.first?.range, wrodAt)
        // Deleting a pending word drops it.
        e.textView.textStorage.replaceCharacters(in: wrodAt, with: "word")
        XCTAssertEqual(s.stepper.pending.map(\.word), ["zorb"])
        XCTAssertEqual(s.stepper.pending.first?.range, (e.textView.text as NSString).range(of: "zorb"))
        // Editing the current word: on to the next.
        e.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 3), with: "The")
        settle()
        XCTAssertEqual(s.current?.word, "zorb")
        s.done()
        // Closed: later edits don't reach it.
        e.textView.textStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x")
        XCTAssertEqual(s.current?.word, "zorb")
    }

    // MARK: The system's underlines

    func testIgnoreAllAndLearnWordRefreshTheSystemUnderlines() throws {
        AppSettings.defaults.set(true, forKey: AppSettings.Key.checkSpellingWhileTyping)
        let md = editor("A zorb, a wrod and a qux.\n")
        md.applyProseChecking()
        XCTAssertEqual(md.textView.spellCheckingType, .yes)
        let checker = FakeChecker(["zorb": [], "wrod": ["word"], "qux": []])
        let s = try XCTUnwrap(md.startFixTypos(checker: checker))
        XCTAssertEqual(md.spellingMarkRefreshes, [])
        s.ignoreAll()
        XCTAssertEqual(checker.ignored, ["zorb"])
        XCTAssertEqual(md.spellingMarkRefreshes, [true], "toggled off and on again")
        XCTAssertEqual(md.textView.spellCheckingType, .yes)
        s.learn()
        XCTAssertEqual(checker.learned, ["wrod"])
        XCTAssertEqual(md.spellingMarkRefreshes, [true, true])
        XCTAssertEqual(md.textView.spellCheckingType, .yes)
        // Skip doesn't recheck.
        s.skip()
        XCTAssertEqual(md.spellingMarkRefreshes, [true, true])
        s.done()

        // Code: the system doesn't check, and isn't turned on.
        let swift = editor("// A zorb and a wrod\n", fileName: "main.swift")
        XCTAssertEqual(swift.textView.spellCheckingType, .no)
        let c = try XCTUnwrap(swift.startFixTypos(checker: FakeChecker(["zorb": [], "wrod": ["word"]])))
        c.ignoreAll()
        c.learn()
        XCTAssertEqual(swift.spellingMarkRefreshes, [false, false])
        XCTAssertEqual(swift.textView.spellCheckingType, .no)
        c.done()

        // Prose with the setting off: stays off.
        AppSettings.defaults.set(false, forKey: AppSettings.Key.checkSpellingWhileTyping)
        let off = editor("A zorb.\n", fileName: "notes.txt")
        off.applyProseChecking()
        XCTAssertEqual(off.textView.spellCheckingType, .no)
        let o = try XCTUnwrap(off.startFixTypos(checker: FakeChecker(["zorb": []])))
        o.learn()
        XCTAssertEqual(off.spellingMarkRefreshes, [false])
        XCTAssertEqual(off.textView.spellCheckingType, .no)
        o.done()
    }

    func testLearnWordWithTheSystemCheckerRefreshesTheUnderlines() throws {
        let language = TextCheckerSpelling.language(for: nil)
        guard language.hasPrefix("en") else { throw XCTSkip("No English checker in this simulator (\(language)).") }
        AppSettings.defaults.set(true, forKey: AppSettings.Key.checkSpellingWhileTyping)
        let word = "Quorblax"
        XCTAssertFalse(UITextChecker.hasLearnedWord(word))
        let e = editor("Some \(word) here.\n")
        e.applyProseChecking()
        let s = try XCTUnwrap(e.startFixTypos())
        XCTAssertEqual(s.current?.word, word)
        // Learn Word writes to the device's dictionary: forgotten again in tearDown.
        learnedForReal.append(word)
        s.learn()
        XCTAssertTrue(UITextChecker.hasLearnedWord(word), "in the device's dictionary")
        XCTAssertEqual(e.spellingMarkRefreshes, [true])
        XCTAssertEqual(e.textView.spellCheckingType, .yes)
        s.done()
    }

    // MARK: The editor going

    private func assertClosed(_ s: SpellStepController, _ e: EditorViewController, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(s.isOpen, file: file, line: line)
        XCTAssertNil(s.card.superview, file: file, line: line)
        XCTAssertNil(e.spellStep, file: file, line: line)
        XCTAssertFalse(s.hasKeyboardObserver, file: file, line: line)
    }

    func testClosingTheDocumentClosesTheCard() throws {
        let e = editor("Teh wrod.\n")
        let s = try XCTUnwrap(e.startFixTypos(checker: FakeChecker(["Teh": ["The"]])))
        XCTAssertTrue(s.isOpen)
        XCTAssertTrue(s.hasKeyboardObserver)
        XCTAssertFalse(e.document.hasUnsavedChanges, "closes without asking")
        // Close → finishClose: the card goes at once, before the document's close finishes.
        e.closeDocument()
        assertClosed(s, e)
        settle(0.2)
        assertClosed(s, e)
    }

    func testLeavingTheParentClosesTheCardButCoveringItDoesNot() throws {
        let e = editor("Teh wrod.\n")
        let nav = try XCTUnwrap(e.navigationController)
        let s = try XCTUnwrap(e.startFixTypos(checker: FakeChecker(["Teh": ["The"]])))
        // Settings (or any sheet) over the editor: it disappears, the card stays.
        let sheet = UIViewController()
        nav.present(sheet, animated: false)
        settle()
        nav.dismiss(animated: false)
        settle()
        XCTAssertTrue(s.isOpen)
        XCTAssertTrue(e.spellStep === s)
        XCTAssertTrue(s.card.superview === e.view)
        XCTAssertTrue(s.hasKeyboardObserver)
        // Removed from its parent: the card goes with it.
        nav.setViewControllers([UIViewController()], animated: false)
        assertClosed(s, e)
    }

    // MARK: Large documents

    func testLargeDocumentScansOnlyAsFarAsTheNextWord() throws {
        let line = String(repeating: "word ", count: 20_000) // one 100 000-character line
        let e = editor("Teh start.\n" + line + "\n", fileName: "long.txt")
        XCTAssertNotNil(e.writingLargeReason)
        let s = try XCTUnwrap(e.startFixTypos(checker: FakeChecker(["Teh": ["The"]])))
        XCTAssertEqual(s.current?.word, "Teh")
        XCTAssertEqual(s.scannedChunks, 1)
        XCTAssertGreaterThan(s.stepper.unscanned.count, SpellStepController.chunksPerTurn)
        settle()
        XCTAssertEqual(s.scannedChunks, 1, "no idle scanning in large mode")
        s.skip()
        // At most four chunks this turn, the rest on later turns.
        XCTAssertEqual(s.scannedChunks, 1 + SpellStepController.chunksPerTurn)
        XCTAssertFalse(s.stepper.isFinished)
        settle(0.2)
        XCTAssertTrue(s.stepper.isFinished)
        s.done()
    }

    func testNormalDocumentCountsTheRestInIdleTurns() throws {
        let e = editor("Teh start.\n" + String(repeating: "word wrod\n", count: 4_000), fileName: "notes.txt")
        XCTAssertNil(e.writingLargeReason)
        let s = try XCTUnwrap(e.startFixTypos(checker: FakeChecker(["Teh": ["The"], "wrod": ["word"]])))
        XCTAssertEqual(s.scannedChunks, 1)
        XCTAssertFalse(s.stepper.progress.final)
        settle(0.3)
        XCTAssertTrue(s.stepper.scanComplete)
        XCTAssertEqual(s.stepper.progress.total, 4_001)
        XCTAssertEqual(s.card.progressLabel.text, String(localized: "\(1) of \(4_001)"))
        s.done()
    }

    // MARK: Keys and the system checker

    func testKeyCommands() throws {
        let e = editor("Teh wrod.\n")
        let s = try XCTUnwrap(e.startFixTypos(checker: FakeChecker(["Teh": ["Tea", "The"], "wrod": ["word"]])))
        let keys = try XCTUnwrap(s.card.keyCommands)
        func has(_ input: String, _ mods: UIKeyModifierFlags = []) -> Bool {
            keys.contains { $0.input == input && $0.modifierFlags == mods }
        }
        XCTAssertTrue(has("\r"))
        XCTAssertTrue(has("\t"))
        XCTAssertTrue(has(UIKeyCommand.inputRightArrow, .command))
        XCTAssertTrue(has(UIKeyCommand.inputEscape))
        XCTAssertTrue(has(UIKeyCommand.inputUpArrow))
        XCTAssertTrue(has(UIKeyCommand.inputDownArrow))
        s.card.keyDown()
        XCTAssertEqual(s.selectedGuess, "The")
        s.card.keyChange()
        XCTAssertTrue(e.textView.text.hasPrefix("The wrod."))
        s.card.keySkip()
        XCTAssertTrue(s.stepper.isFinished)
        s.card.keyDone()
        XCTAssertNil(e.spellStep)
    }

    func testSystemCheckerFindsAndSuggests() throws {
        let language = TextCheckerSpelling.language(for: nil)
        guard language.hasPrefix("en") else { throw XCTSkip("No English checker in this simulator (\(language)).") }
        let checker = TextCheckerSpelling(language: language)
        let text = "I will recieve the parcel tomorow."
        let found = checker.misspellings(in: text).map { (text as NSString).substring(with: $0) }
        XCTAssertEqual(found, ["recieve", "tomorow"])
        XCTAssertEqual(checker.guesses(for: "recieve").first, "receive")
        checker.ignore("recieve")
        XCTAssertEqual(checker.misspellings(in: text).map { (text as NSString).substring(with: $0) }, ["tomorow"])

        // Learn Word writes to the device's dictionary: forgotten again in tearDown.
        let word = "Zorbulix"
        XCTAssertFalse(UITextChecker.hasLearnedWord(word))
        learnedForReal.append(word)
        checker.learn(word)
        XCTAssertTrue(UITextChecker.hasLearnedWord(word))

        // End to end on a Markdown document with the system's checker.
        let e = editor("Some recieve text with `tomorow` in code.\n")
        let s = try XCTUnwrap(e.startFixTypos())
        XCTAssertEqual(s.current?.word, "recieve")
        XCTAssertEqual(s.selectedGuess, "receive")
        s.change()
        XCTAssertTrue(e.textView.text.hasPrefix("Some receive text"))
        XCTAssertTrue(s.stepper.isFinished)
        s.done()
    }
}
