import Combine
import XCTest
import CedricCore
import CedricAI

@MainActor
final class AskChunkedReviewTests: XCTestCase {
    func testWholeDocumentReviewShowsProgressAndMergedAnswer() async throws {
        let text = (1...2000).map { "Line \($0): some text in this document" }.joined(separator: "\n")
        let snap = OwlDocumentSnapshot(text: text, generation: 0)
        let engine = FakeChatEngine(delay: 0.001)
        let question = "What does this document say?"
        let model = AskCedricModel(fileName: nil, language: .plain)
        model.makeSnapshot = { snap }
        model.settingsProvider = { .default }
        model.makeEngine = { _ in engine }
        await model.prepare()
        model.selectScope(.wholeDocument)

        let tools = OwlToolGate.bundled().allowsTools(engine.scoreKey)
        let context = try XCTUnwrap(OwlChatRequest.documentContext(snap, scope: .wholeDocument,
                                                                    engineBudget: engine.contextBudget, history: [],
                                                                    question: question, action: nil, tools: tools,
                                                                    server: engine.usesServer, prose: true))
        let request = OwlChatRequest(question: question, action: nil, context: context, snapshot: snap,
                                     useTools: tools, prose: true)
        let plan = try XCTUnwrap(OwlChunkedReviewRunner.plan(request, engine: engine))
        XCTAssertGreaterThan(plan.parts.count, 1)

        var progress: [String] = []
        let subscription = model.$reviewProgress.compactMap { $0 }.sink { progress.append($0) }
        model.ask(question)
        let finished = expectation(description: "review finishes")
        let completion = model.$running.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        await fulfillment(of: [finished], timeout: 20)
        withExtendedLifetime((subscription, completion)) {}

        XCTAssertFalse(progress.isEmpty)
        XCTAssertTrue(progress.allSatisfy { $0 == String(localized: "Reviewing…") })
        XCTAssertTrue(progress.allSatisfy { !$0.localizedCaseInsensitiveContains("part") })
        XCTAssertEqual(model.entries.last?.role, .owl)
        let answer = try XCTUnwrap(model.entries.last?.text)
        XCTAssertFalse(answer.isEmpty)
        XCTAssertFalse(answer.localizedCaseInsensitiveContains("part 1 of"))
        XCTAssertFalse(answer.contains("Part 1 (lines"))
    }

    func testStopBeforeFirstPartShowsStoppedNote() async throws {
        let text = (1...2000).map { "Line \($0): some text in this document" }.joined(separator: "\n")
        let model = AskCedricModel(fileName: nil, language: .plain)
        model.makeSnapshot = { OwlDocumentSnapshot(text: text, generation: 0) }
        model.settingsProvider = { .default }
        let started = expectation(description: "engine requested")
        model.makeEngine = { _ in
            started.fulfill()
            try? await Task.sleep(for: .seconds(10))
            return FakeChatEngine(delay: 0)
        }
        model.refreshScope()
        model.selectScope(.wholeDocument)
        model.ask("What does this document say?")
        let finished = expectation(description: "stopped review finishes")
        let completion = model.$running.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }
        await fulfillment(of: [started], timeout: 5)
        model.stop()
        await fulfillment(of: [finished], timeout: 5)
        withExtendedLifetime(completion) {}
        XCTAssertEqual(model.entries.last?.role, .note)
        XCTAssertEqual(model.entries.last?.text, String(localized: "Stopped."))
        XCTAssertNil(model.reviewProgress)
    }
}
