import Foundation
import Testing
@testable import CedricAI

/// What LM Studio and Ollama say about a model's context window: parsing
/// (fixtures), the probe (the in-process stub server; no real server) and
/// the cache behind `ServerChatEngine.contextBudget`.
@Suite struct ServerContextParseTests {
    func data(_ o: Any) -> Data { try! JSONSerialization.data(withJSONObject: o) }

    @Test func lmStudioLoadedModelReportsItsLoadedContext() {
        let body = data(["data": [
            ["id": "other", "state": "loaded", "loaded_context_length": 32_768, "max_context_length": 32_768],
            ["id": "qwen3-4b", "type": "llm", "state": "loaded", "loaded_context_length": 4_096, "max_context_length": 262_144],
        ]])
        #expect(ServerContextReport.lmStudio(body, model: "qwen3-4b") == ServerContextReport(tokens: 4_096, source: .loaded))
        #expect(ServerContextReport.lmStudio(body, model: "other") == ServerContextReport(tokens: 32_768, source: .loaded))
    }

    @Test func lmStudioUnloadedModelGetsTheDefaultLoadCappedByItsMaximum() {
        let body = data(["data": [
            ["id": "big", "state": "not-loaded", "max_context_length": 131_072],
            ["id": "tiny", "state": "not-loaded", "max_context_length": 2_048],
            ["id": "bare", "state": "not-loaded"],
        ]])
        #expect(ServerContextReport.lmStudio(body, model: "big") == ServerContextReport(tokens: 4_096, source: .serverDefault))
        #expect(ServerContextReport.lmStudio(body, model: "tiny") == ServerContextReport(tokens: 2_048, source: .serverDefault))
        #expect(ServerContextReport.lmStudio(body, model: "bare") == ServerContextReport(tokens: 4_096, source: .serverDefault))
    }

    @Test func lmStudioWithoutTheModelOrNotJSONSaysNothing() {
        #expect(ServerContextReport.lmStudio(data(["data": [["id": "x"]]]), model: "y") == nil)
        #expect(ServerContextReport.lmStudio(Data("<html>".utf8), model: "y") == nil)
        #expect(ServerContextReport.lmStudio(data(["object": "list"]), model: "y") == nil)
        // A loaded model with a nonsense length falls back to the default load.
        let odd = data(["data": [["id": "m", "state": "loaded", "loaded_context_length": 0]]])
        #expect(ServerContextReport.lmStudio(odd, model: "m") == ServerContextReport(tokens: 4_096, source: .serverDefault))
    }

    @Test func ollamaPSFindsTheLoadedModelByNameOrLatestTag() {
        let body = data(["models": [
            ["name": "llama3.2:latest", "model": "llama3.2:latest", "context_length": 8_192],
            ["name": "qwen3:4b", "model": "qwen3:4b", "size_vram": 5_000_000_000, "context_length": 16_384],
        ]])
        #expect(ServerContextReport.ollamaLoaded(body, model: "qwen3:4b") == 16_384)
        #expect(ServerContextReport.ollamaLoaded(body, model: "llama3.2") == 8_192)
        #expect(ServerContextReport.ollamaLoaded(body, model: "qwen3:8b") == nil)
        #expect(ServerContextReport.ollamaLoaded(data(["models": [["name": "qwen3:4b"]]]), model: "qwen3:4b") == nil,
                "an older Ollama without context_length")
    }

    @Test func ollamaShowReadsNumCtxAndTheModelMaximum() throws {
        let show = data([
            "parameters": "stop                           \"<|im_end|>\"\nnum_ctx                        12288\ntemperature 0.6",
            "model_info": ["general.architecture": "qwen3", "qwen3.context_length": 40_960, "qwen3.block_count": 36],
            "details": ["family": "qwen3"],
        ])
        let parsed = try #require(ServerContextReport.ollamaShow(show))
        #expect(parsed.configured == 12_288)
        #expect(parsed.maximum == 40_960)
        #expect(ServerContextReport.ollama(loaded: nil, show: parsed) == ServerContextReport(tokens: 12_288, source: .configured))
        #expect(ServerContextReport.ollama(loaded: 8_192, show: parsed) == ServerContextReport(tokens: 8_192, source: .loaded))
    }

    @Test func ollamaWithoutNumCtxUsesItsDefaultLoad() throws {
        let plain = try #require(ServerContextReport.ollamaShow(data(["model_info": ["llama.context_length": 131_072]])))
        #expect(ServerContextReport.ollama(loaded: nil, show: plain) == ServerContextReport(tokens: 4_096, source: .serverDefault))
        let small = try #require(ServerContextReport.ollamaShow(data(["model_info": ["gemma.context_length": 2_048],
                                                                      "parameters": "num_ctx 8192"])))
        #expect(ServerContextReport.ollama(loaded: nil, show: small) == ServerContextReport(tokens: 2_048, source: .configured),
                "num_ctx above the model's maximum is capped")
        #expect(ServerContextReport.ollamaShow(data(["error": "model not found"])) == nil)
        #expect(ServerContextReport.ollama(loaded: nil, show: nil) == nil)
    }

    @Test func modelMaximumPrefersTheArchitectureKeyElseTheSmallestPlausible() {
        let info: [String: Any] = ["general.architecture": "qwen3", "clip.context_length": 2_048,
                                   "qwen3.context_length": 40_960, "zeta.context_length": 8_192]
        #expect(ServerContextReport.modelMaximum(info) == 40_960, "the architecture's own key, whatever the order")
        #expect(ServerContextReport.modelMaximum(["b.context_length": 32_768, "a.context_length": 8_192]) == 8_192,
                "no architecture: the smallest")
        #expect(ServerContextReport.modelMaximum(["general.architecture": "llama", "llama.context_length": 0,
                                                  "x.context_length": 16_384, "y.context_length": 1]) == 16_384,
                "an implausible key is skipped, not fatal")
        #expect(ServerContextReport.modelMaximum(["general.architecture": "llama", "llama.block_count": 32]) == nil)
        // Every order of the same keys gives the same answer.
        let keys = ["a.context_length", "b.context_length", "c.context_length"]
        let values = [65_536, 4_096, 131_072]
        for _ in 0..<20 {
            let shuffled = Dictionary(uniqueKeysWithValues: zip(keys.shuffled(), values.shuffled()))
            #expect(ServerContextReport.modelMaximum(shuffled) == 4_096)
        }
        let show = data(["model_info": info, "parameters": "num_ctx 65536"])
        #expect(ServerContextReport.ollamaShow(show)?.maximum == 40_960)
    }
}

@Suite(.timely) struct ServerContextProbeTests {
    @Test func lmStudioServerIsAskedOnItsNativeList() async {
        let server = StubServer()
        server.json("/api/v0/models", ["data": [["id": "qwen3-4b", "state": "loaded", "loaded_context_length": 8_192]]])
        let client = LocalModelClient(baseURL: server.baseURL, timeout: 5, session: server.session)
        #expect(await client.contextReport(model: "qwen3-4b", kind: .lmStudio) == ServerContextReport(tokens: 8_192, source: .loaded))
        #expect(!server.recorded.contains { $0.path.hasPrefix("/api/ps") || $0.path.hasPrefix("/api/show") })
    }

    @Test func ollamaServerIsAskedPSThenShow() async throws {
        let server = StubServer()
        server.json("/api/ps", ["models": []])
        server.json("/api/show", ["parameters": "num_ctx 6144", "model_info": ["qwen3.context_length": 40_960]])
        let client = LocalModelClient(baseURL: server.baseURL, timeout: 5, session: server.session)
        #expect(await client.contextReport(model: "qwen3:4b", kind: .ollama) == ServerContextReport(tokens: 6_144, source: .configured))
        let show = try #require(server.recorded.first { $0.path == "/api/show" }?.body)
        let sent = try #require(try JSONSerialization.jsonObject(with: show) as? [String: String])
        #expect(sent["model"] == "qwen3:4b")
        #expect(!server.recorded.contains { $0.path == "/api/v0/models" }, "Ollama isn't asked LM Studio's list")
    }

    @Test func customServerTriesLMStudioThenOllama() async {
        let server = StubServer()
        server.json("/api/ps", ["models": [["model": "m:latest", "context_length": 32_768]]])
        let client = LocalModelClient(baseURL: server.baseURL, timeout: 5, session: server.session)
        #expect(await client.contextReport(model: "m", kind: .custom) == ServerContextReport(tokens: 32_768, source: .loaded))
    }

    @Test func aServerThatSaysNothingOrFailsGivesNil() async {
        let server = StubServer()   // every path 404
        let client = LocalModelClient(baseURL: server.baseURL, timeout: 5, session: server.session)
        #expect(await client.contextReport(model: "m", kind: .custom) == nil)
        #expect(await client.contextReport(model: "m", kind: .lmStudio) == nil)
        let slow = StubServer()
        slow.json("/api/v0/models", ["data": [["id": "m", "state": "loaded", "loaded_context_length": 8_192]]], delay: 3_600)
        let quick = LocalModelClient(baseURL: slow.baseURL, timeout: 0.2, session: slow.session)
        #expect(await quick.contextReport(model: "m", kind: .lmStudio) == nil, "past the deadline")
        let public_ = LocalModelClient(baseURL: URL(string: "http://example.com/v1")!, timeout: 1, session: server.session)
        #expect(await public_.contextReport(model: "m", kind: .lmStudio) == nil, "not a local server: never asked")
    }
}

@Suite(.timeLimit(.minutes(1))) struct ServerContextCacheTests {
    final class Fake: @unchecked Sendable {
        let lock = NSLock()
        var time: TimeInterval = 1_000
        var calls = 0
        var answer: ServerContextReport? = ServerContextReport(tokens: 4_096, source: .loaded)
        var now: TimeInterval { lock.withLock { time } }
        func probe() -> ServerContextReport? { lock.withLock { answer } }
        func called() { lock.withLock { calls += 1 } }
        func advance(_ s: TimeInterval) { lock.withLock { time += s } }
        var count: Int { lock.withLock { calls } }
        func set(_ r: ServerContextReport?) { lock.withLock { answer = r } }
    }

    let client = LocalModelClient(baseURL: URL(string: "http://localhost:1234/v1")!)

    /// A probe that answers only once opened: no real time decides who
    /// ends first.
    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = false
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let now: Bool = lock.withLock { if open { return true }; waiting.append(c); return false }
                if now { c.resume() }
            }
        }
        func release() {
            let all: [CheckedContinuation<Void, Never>] = lock.withLock { open = true; defer { waiting = [] }; return waiting }
            all.forEach { $0.resume() }
        }
    }

    /// `refresh` waits an hour unless told otherwise, so only the probe
    /// (instant, or held by `gate`) decides what it returns.
    func cache(_ fake: Fake, gate: Gate? = nil) -> ServerContextCache {
        ServerContextCache(now: { fake.now }, defaultWait: 3_600, probe: { _, _, _ in
            fake.called()
            await gate?.wait()
            return fake.probe()
        })
    }

    @Test func engineBudgetFollowsTheServersContext() async {
        let fake = Fake()
        let contexts = cache(fake)
        let engine = ServerChatEngine(client: client, model: "m", kind: .lmStudio, contexts: contexts)
        #expect(engine.contextBudget == 32_000 || engine.contextBudget == 4_608, "nothing known yet, or the probe was quick")
        await engine.discoverContext()
        #expect(engine.contextBudget == 4_608)
        fake.set(nil)
        fake.advance(301)
        await engine.discoverContext()
        #expect(engine.contextBudget == 32_000, "the server stopped saying: the cap again")
    }

    @Test func aLoadedReportIsKeptFiveMinutesAGuessThirtySeconds() async {
        let fake = Fake()
        let contexts = cache(fake)
        _ = await contexts.refresh(client: client, model: "m", kind: .lmStudio)
        #expect(fake.count == 1)
        fake.advance(299)
        _ = await contexts.refresh(client: client, model: "m", kind: .lmStudio)
        #expect(contexts.current(client: client, model: "m", kind: .lmStudio)?.tokens == 4_096)
        #expect(fake.count == 1, "fresh: not asked again")
        fake.set(ServerContextReport(tokens: 4_096, source: .serverDefault))
        fake.advance(2)
        _ = await contexts.refresh(client: client, model: "m", kind: .lmStudio)
        #expect(fake.count == 2)
        fake.advance(29)
        _ = await contexts.refresh(client: client, model: "m", kind: .lmStudio)
        #expect(fake.count == 2)
        fake.advance(2)
        _ = await contexts.refresh(client: client, model: "m", kind: .lmStudio)
        #expect(fake.count == 3, "a guess is checked again after 30 s")
        _ = await contexts.refresh(client: client, model: "other", kind: .lmStudio)
        #expect(fake.count == 4, "per model")
    }

    @Test func aSlowProbeDoesNotHoldTheEngineAndIsAskedOnce() async {
        let fake = Fake()
        let gate = Gate()
        let contexts = cache(fake, gate: gate)
        // The probe can't answer until the gate opens: the short wait ends first.
        #expect(await contexts.refresh(client: client, model: "m", kind: .ollama, wait: 0.01) == nil, "the wait ends first")
        #expect(contexts.current(client: client, model: "m", kind: .ollama) == nil)
        // A second wait joins the same probe (still held), then the probe answers.
        let second = Task { await contexts.refresh(client: client, model: "m", kind: .ollama, wait: 3_600) }
        gate.release()
        #expect(await second.value?.tokens == 4_096)
        #expect(fake.count == 1, "one probe in flight, shared")
        #expect(contexts.current(client: client, model: "m", kind: .ollama)?.tokens == 4_096)
    }

    @Test func anAnswerAfterTheDeadlineIsLateEvenWhenItArrivesFirst() async {
        let fake = Fake()
        let contexts = cache(fake)
        // wait 0: the deadline has passed before the probe can answer, so
        // the instant answer is late, whichever task the pool runs first.
        #expect(await contexts.refresh(client: client, model: "m", kind: .lmStudio, wait: 0) == nil)
        // It is still stored: the next read has it, without a second probe.
        #expect(await contexts.refresh(client: client, model: "m", kind: .lmStudio)?.tokens == 4_096)
        #expect(fake.count == 1)
    }
}
