import XCTest
import SwiftUI
import CedricCore
import CedricAI

/// An engine that records who asked (`BuiltInLoad.intent`) and can hold
/// its answer until released or cancelled.
private actor IntentEngine: OwlChatEngine {
    nonisolated let title = "Intent engine"
    nonisolated let scoreKey = "fake"
    nonisolated let contextBudget = 6_000
    private var intents: [BuiltInLoadIntent] = []
    private var questions: [String] = []
    private let holdFirst: Bool
    private var released = false
    private var reason: String

    init(holdFirst: Bool = false, answer: String = "Answer") {
        self.holdFirst = holdFirst
        self.reason = answer
    }

    func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
              onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
        intents.append(BuiltInLoad.intent)
        let q = messages.compactMap { m -> String? in if case .user(let s) = m { return s }; return nil }.last ?? ""
        questions.append(q)
        if holdFirst, questions.count == 1 {
            // The first question waits (a long prefill) until cancelled.
            while !released { try await Task.sleep(for: .milliseconds(5)) }
            onText("late text from the first question")
            return .answer("First answer")
        }
        return .answer(reason)
    }

    func release() { released = true }
    func recordedIntents() -> [BuiltInLoadIntent] { intents }
    func recordedCount() -> Int { questions.count }
}

/// An engine that proposes one edit (a tool call), then claims it "Fixed" it.
private actor ProposingEngine: OwlChatEngine {
    nonisolated let title = "Proposing engine"
    nonisolated let scoreKey: String
    nonisolated let contextBudget = 6_000
    init(scoreKey: String) { self.scoreKey = scoreKey }

    func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
              onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
        let results = messages.filter { if case .toolResult = $0 { return true }; return false }
        if results.isEmpty, tools.contains(where: { $0.name == .proposeEdit }) {
            return .toolCalls([OwlToolCall(id: "e", name: "propose_edit", arguments: .object([
                "find": .string("A secnod line."), "replace": .string("A second line."), "reason": .string("Fixed the typo")]))])
        }
        let a = "Fixed the typo."
        onText(a)
        return .answer(a)
    }
}

@MainActor
final class AskLifecycleTests: XCTestCase {
    private func model(_ engine: IntentEngine, text: String = "Some notes.\nA second line.\n") -> AskCedricModel {
        let m = AskCedricModel(fileName: "notes.md", language: .markdown)
        m.makeSnapshot = { OwlDocumentSnapshot(text: text, generation: 1, fileName: "notes.md", language: "markdown") }
        m.settingsProvider = { .default }
        m.makeEngine = { _ in engine }
        return m
    }

    private func waitFor(_ timeout: TimeInterval = 10, _ cond: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await cond()), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// Ask Cedric is something the user asked for: it may load the built-in
    /// model (0.5.3). Unmarked work stays automatic and may not.
    func testAskRunsAsUserAsked() async {
        XCTAssertEqual(BuiltInLoad.intent, .automatic)
        let engine = IntentEngine()
        let m = model(engine)
        m.ask("What is this about?")
        await m.task?.value
        let intents = await engine.recordedIntents()
        XCTAssertEqual(intents, [.userAsked])
        XCTAssertFalse(m.running)
        XCTAssertNil(m.startedAt)
    }

    /// A new question while one is still processing doesn't wait behind it:
    /// the first is abandoned, and nothing it delivers later shows.
    func testNewQuestionSupersedesTheRunningOne() async {
        let engine = IntentEngine(holdFirst: true, answer: "Second answer")
        let m = model(engine)
        m.ask("First question")
        XCTAssertTrue(m.running)
        XCTAssertNotNil(m.startedAt, "the waiting label counts from here")
        let first = m.task
        await waitFor { await engine.recordedCount() == 1 }
        m.ask("Second question")
        XCTAssertEqual(m.abandonedCount, 1)
        await m.task?.value
        await engine.release()
        await first?.value
        try? await Task.sleep(for: .milliseconds(80))
        let owl = m.entries.filter { $0.role == .owl }.map(\.text)
        XCTAssertEqual(owl, ["Second answer"])
        XCTAssertFalse(m.entries.contains { $0.text.contains("late text") || $0.text.contains("First answer") })
        XCTAssertEqual(m.entries.map(\.role), [.user, .note, .user, .owl])
        XCTAssertEqual(m.entries[1].text, String(localized: "Stopped."))
        XCTAssertFalse(m.running)
    }

    /// "Fix the typos" opens Fix Typos (offline); no engine is asked.
    func testSpellingRequestOpensFixTypos() async {
        let engine = IntentEngine()
        let m = model(engine)
        var routed = 0
        m.routeSpelling = { routed += 1; return .opened }
        m.ask("Fix the spelling mistakes.")
        XCTAssertEqual(routed, 1)
        XCTAssertFalse(m.running)
        XCTAssertEqual(m.entries.map(\.role), [.user, .note])
        XCTAssertEqual(m.entries.last?.text, AskCedricModel.spellingRoutedNote)
        XCTAssertFalse(AskCedricModel.spellingRoutedNote.contains("Mac"))
        let count = await engine.recordedCount()
        XCTAssertEqual(count, 0)
        // A data file: nothing to step through, said so.
        m.routeSpelling = { .notChecked }
        m.ask("fix typos")
        XCTAssertEqual(m.entries.last?.text, OwlSpellingIntent.notCheckedNote)
        // Not a spelling request: the model answers.
        m.ask("Explain the second line.")
        await m.task?.value
        let after = await engine.recordedCount()
        XCTAssertEqual(after, 1)
    }

    /// Over the auto-review cap, the first request is confirmed (Cancel
    /// does nothing); once confirmed it isn't asked again.
    func testCappedFileAsksOnceBeforeAsking() async {
        let engine = IntentEngine()
        let m = model(engine)
        let size = AutoReviewCap.Size(utf8Bytes: 730_000, lines: 6_132)
        m.autoReviewCapped = { size }
        var confirmedInEditor = false
        m.onCapConfirmed = { confirmedInEditor = true }
        m.ask("What is this about?")
        XCTAssertEqual(m.capConfirmation?.title, AutoReviewCap.confirmation(fileName: "notes.md", size: size).title)
        XCTAssertTrue(m.entries.isEmpty)
        m.answerCapConfirmation(false)
        XCTAssertNil(m.capConfirmation)
        XCTAssertTrue(m.entries.isEmpty, "Cancel asks nothing")
        m.ask("What is this about?")
        XCTAssertNotNil(m.capConfirmation)
        m.answerCapConfirmation(true)
        XCTAssertTrue(confirmedInEditor)
        XCTAssertTrue(m.running)
        await m.task?.value
        XCTAssertEqual(m.entries.filter { $0.role == .owl }.map(\.text), ["Answer"])
        m.ask("And the second line?")
        XCTAssertNil(m.capConfirmation, "asked once per document")
        await m.task?.value
    }

    /// Automatic owl checks skip a capped document; the editor says so in
    /// the snapshot (100 KB or 2,000 lines).
    func testEditorReportsAutoReviewCap() {
        let small = editor("A short note.\n")
        XCTAssertNil(small.autoReviewCapSize)
        let lines = editor(String(repeating: "line\n", count: AutoReviewCap.maxLines + 1))
        XCTAssertEqual(lines.autoReviewCapSize?.lines, AutoReviewCap.maxLines + 1)
        let bytes = editor(String(repeating: "é", count: AutoReviewCap.maxUTF8Bytes / 2 + 1))
        XCTAssertEqual(bytes.autoReviewCapSize?.utf8Bytes, AutoReviewCap.maxUTF8Bytes + 2)
    }

    /// Load model at launch: off by default, built-in engine only, and only
    /// where the built-in runtime exists (a device, never the simulator).
    func testPreloadOnlyWhenOptedIn() {
        var s = LocalAISettings.default
        XCTAssertFalse(s.loadModelAtLaunch)
        s.enabled = true
        s.backend = .builtIn
        XCTAssertFalse(BuiltInPreload.shouldPreload(settings: s, available: true))
        s.loadModelAtLaunch = true
        XCTAssertTrue(BuiltInPreload.shouldPreload(settings: s, available: true))
        XCTAssertFalse(BuiltInPreload.shouldPreload(settings: s, available: false))
        s.backend = .apple
        XCTAssertFalse(BuiltInPreload.shouldPreload(settings: s, available: true))
        s.backend = .builtIn
        s.enabled = false
        XCTAssertFalse(BuiltInPreload.shouldPreload(settings: s, available: true))
        #if targetEnvironment(simulator)
        XCTAssertFalse(BuiltInEngine().isAvailable, "no llama.cpp slice on the simulator")
        #endif
    }

    /// An Ask answer with a proposal: the transcript words the model's
    /// "Fixed …" as a proposal, a note says nothing is applied, and the
    /// card shows the badge and the reason worded as a proposal.
    func testProposalWording() async throws {
        XCTAssertEqual(OwlProposalWording.badge, "Proposed, not applied")
        let gate = OwlToolGate.bundled()
        let key = try XCTUnwrap(gate.scores.keys.first(where: { gate.allowsTools($0) }))
        let engine = ProposingEngine(scoreKey: key)
        let text = "Some notes.\nA secnod line.\n"
        let m = AskCedricModel(fileName: "notes.md", language: .markdown)
        m.makeSnapshot = { OwlDocumentSnapshot(text: text, generation: 1, fileName: "notes.md", language: "markdown") }
        m.documentNow = {
            AskCedricModel.DocumentNow(text: text as NSString, generation: 1, readOnly: false, large: false, lines: LineIndex(text as NSString))
        }
        m.settingsProvider = { LocalAISettings(enabled: true, backend: .ollama, model: "test") }
        m.makeEngine = { _ in engine }
        m.ask("Please correct the second line.")
        await waitFor { !m.running && m.entries.contains { !$0.cards.isEmpty } }
        let answer = try XCTUnwrap(m.entries.first { !$0.cards.isEmpty }, "\(m.entries.map { "\($0.role): \($0.text)" })")
        XCTAssertEqual(answer.role, .owl)
        XCTAssertFalse(answer.text.contains("Fixed"), answer.text)
        XCTAssertTrue(answer.text.contains("Proposed fix: the typo"), answer.text)
        XCTAssertTrue(m.entries.contains { $0.role == .note && $0.text == OwlProposalWording.header(count: 1) },
                      "\(m.entries.map(\.text))")
        let card = try XCTUnwrap(answer.cards.first)
        XCTAssertEqual(card.proposal.replacement, "A second line.")
        let view = AskEditCard(entry: answer.id, card: card, count: 1, colors: AskColors(EditorPalettes.light),
                               apply: {}, skip: {}, showAll: {}, askAgain: {}, noteWidth: { _ in })
        XCTAssertEqual(view.reason, "Proposed fix: the typo")
        XCTAssertTrue(view.label.hasPrefix(view.title + ", " + OwlProposalWording.badge + ": Proposed fix: the typo"), view.label)
    }

    private var windows: [UIWindow] = []
    override func tearDown() async throws {
        for w in windows { w.isHidden = true; w.rootViewController = nil }
        windows = []
    }

    private func editor(_ text: String) -> EditorViewController {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent("notes.txt")
        let doc = TextDocument(fileURL: url)
        doc.text = text
        doc.language = .forFile(named: "notes.txt", content: text)
        let editor = EditorViewController(document: doc, readModeOnOpen: false)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        window.rootViewController = UINavigationController(rootViewController: editor)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        windows.append(window)
        return editor
    }
}
