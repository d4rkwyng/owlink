import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// An empty or tiny document is never sent to an AI for hints. The prompt
/// wraps the text in a code fence, so a blank Plain Text file looks like
/// an empty code block and the model invents one.
@Suite struct ShortDocumentGateTests {
    @Test func enoughTextIsTwentyNonWhitespaceCharacters() {
        #expect(HintPrompt.minimumHintCharacters == 20)
        #expect(!HintPrompt.hasEnoughText(""))
        #expect(!HintPrompt.hasEnoughText("   \n\t  \n"))
        #expect(!HintPrompt.hasEnoughText(String(repeating: "a", count: 19)))
        #expect(!HintPrompt.hasEnoughText(String(repeating: "a ", count: 19)))
        #expect(HintPrompt.hasEnoughText(String(repeating: "a", count: 20)))
        #expect(HintPrompt.hasEnoughText(String(repeating: "a ", count: 20)))
        #expect(HintPrompt.hasEnoughText("let value = items.count + 1"))
    }

    /// Automatic checks and the pause timer, and Ask AI Now.
    @Test func schedulerDoesNotRequestHintsForAShortDocument() async {
        let rig = SchedulerTests.Rig()
        let doc = UUID()
        await rig.scheduler.contextChanged(context("", gen: 1, doc: doc, language: "plain", file: "Untitled.txt"))
        await rig.advance(30)
        #expect(await rig.scheduler.gate(for: doc) == .tooShort)
        #expect(await rig.scheduler.timerFired(doc) == .tooShort)

        await rig.scheduler.contextChanged(context("   \n\t", gen: 2, doc: doc, language: "plain", file: "Untitled.txt"))
        await rig.advance(10)
        await rig.scheduler.contextChanged(context("Hello from Cedric.", gen: 3, doc: doc, language: "plain", file: "Untitled.txt"))
        await rig.advance(10)
        #expect(await rig.scheduler.gate(for: doc) == .tooShort)
        #expect(await rig.scheduler.checkNow(context("", gen: 4, doc: doc, language: "plain")) == false)
        #expect(await rig.scheduler.checkNow(context(String(repeating: "a", count: 19), gen: 4, doc: doc)) == false)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls.isEmpty)
        #expect(await rig.scheduler.requestCount == 0)

        let enough = String(repeating: "a", count: 20)
        await rig.scheduler.contextChanged(context(enough, gen: 5, doc: doc, language: "plain"))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [5] })
        #expect(await rig.scheduler.requestCount == 1)
    }

    @MainActor @Test func askingNowDoesNotStartAShortDocument() async {
        let registry = OwlProviderRegistry()
        let provider = FakeProvider()
        let bridge = LocalAIOwlBridge(registry: registry, engine: { _ in AppleIntelligenceEngine(status: .available) },
                                      makeProvider: { _ in provider })
        let s = LocalAISettings(enabled: true, backend: .apple, minInterval: 0.1, pauseDelay: 0.05, minIdle: 0)
        await bridge.apply(s)
        let doc = UUID()
        #expect(bridge.checkNow(context("", gen: 1, doc: doc, language: "plain", file: "Untitled.txt")) == false)
        bridge.contextChanged(context("Just a note.", gen: 2, doc: doc, language: "plain", file: "Untitled.txt"))
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(provider.calls.isEmpty)
        #expect(bridge.checkNow(context(String(repeating: "b", count: 20), gen: 3, doc: doc, language: "plain")))
        #expect(await eventually { provider.calls == [3] })
    }

    @Test func noEngineIsCalledForAShortDocument() async throws {
        let empty = context("", language: "plain", file: "Untitled.txt")
        let server = StubServer()
        server.json("/v1/chat/completions", chatCompletion(#"{"hints":[{"kind":"warning","title":"Empty code block","detail":"The code has no content.","find":"","replacement":"","confidence":0.9}]}"#))
        let local = LocalModelHintProvider(client: LocalModelClient(baseURL: server.baseURL, session: server.session), model: "m")
        #expect(await local.hints(for: empty).isEmpty)
        #expect(try await local.requestHints(for: empty).isEmpty)
        #expect(server.recorded.isEmpty)

        let rt = FakeRuntime()
        let model = testModel(body: Data("x".utf8))
        let builtIn = BuiltInHintProvider(model: model, path: URL(fileURLWithPath: "/tmp/empty.gguf"),
                                          host: BuiltInModelHost(runtime: rt))
        let built = await builtIn.hints(for: empty)
        #expect(built.isEmpty)
        #expect(rt.loads.value.isEmpty)
        #expect(rt.requests.value.isEmpty)

        let apple = await AppleFoundationModelsProvider().hints(for: empty)
        #expect(apple.isEmpty)
    }
}
