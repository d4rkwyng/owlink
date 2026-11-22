import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The settings sheet's model and the registry/scheduler wiring the app
/// uses (`LocalAIOwlBridge`), with fake providers and the stub server.
@Suite struct SettingsTests {
    @Test func offByDefaultWithNinetySecondInterval() {
        let s = LocalAISettings.default
        #expect(s.enabled == false)
        #expect(s.minInterval == 90)
        #expect(s.backend == .builtIn)   // Cedric's own engine: no server needed
        #expect(s.baseURL.absoluteString == "http://localhost:1234/v1")
        #expect(s.isUsable == false)
        #expect(LocalAISettings.intervalChoices.contains(90))
        #expect(LocalAISettings.privacyNote == "Sends only the visible text (up to 8 KB) to the address above. Never the cloud.")
        #expect(LocalAISettings.weakModelNote == "Small models give weaker hints.")
    }

    @Test func presetsSetTheirURLAndResetTheModel() {
        var s = LocalAISettings(enabled: true, model: "qwen3-4b")
        s.selectBackend(.ollama)
        #expect(s.baseURL.absoluteString == "http://localhost:11434/v1")
        #expect(s.model == nil)
        s.baseURL = URL(string: "http://studio.local:1234/v1")!
        s.selectBackend(.custom)
        #expect(s.baseURL.absoluteString == "http://studio.local:1234/v1")   // Custom keeps what's there
        s.selectBackend(.lmStudio)
        #expect(s.baseURL.absoluteString == "http://localhost:1234/v1")
        #expect(LocalAISettings.Backend.allCases.map(\.title) == ["Built-in (on this Mac)", "LM Studio on this Mac", "Ollama on this Mac",
                                                                "Another Mac on your network (URL)", "Apple Intelligence (on this Mac, private)"])
    }

    @Test func customURLParsing() {
        #expect(LocalAISettings.parseEndpoint("studio.local:1234")?.absoluteString == "http://studio.local:1234/v1")
        #expect(LocalAISettings.parseEndpoint(" http://192.168.1.20:11434/ ")?.absoluteString == "http://192.168.1.20:11434/v1")
        #expect(LocalAISettings.parseEndpoint("http://10.0.0.5:8080/v1/")?.absoluteString == "http://10.0.0.5:8080/v1")
        #expect(LocalAISettings.parseEndpoint("https://api.openai.com/v1") == nil)
        #expect(LocalAISettings.parseEndpoint("8.8.8.8:1234") == nil)
        #expect(LocalAISettings.parseEndpoint("") == nil)
    }

    @Test func savesAndLoadsFromDefaults() throws {
        let (d, suite) = TestDefaults.make("cedric-tests-")
        defer { TestDefaults.remove(suite) }
        #expect(LocalAISettings.load(from: d, defaultBackend: .builtIn) == .default)
        var s = LocalAISettings(enabled: true, backend: .ollama, model: "qwen2.5-coder:3b", minInterval: 120)
        s.save(to: d)
        #expect(LocalAISettings.load(from: d) == s)
        s.enabled = false
        s.save(to: d)
        #expect(LocalAISettings.load(from: d).enabled == false)
    }

    /// An address that isn't local applies nothing, except turning AI off.
    @Test func invalidAddressAppliesNothingExceptTurningAIOff() {
        let url = URL(string: "http://192.168.1.20:1234/v1")!
        let s = LocalAISettings(enabled: true, backend: .custom, baseURL: url, model: "qwen",
                                minInterval: 90, pauseDelay: 7, timeout: 11, minIdle: 3, automaticChecks: true)
        let bad = "https://api.openai.com/v1"
        let turningOff = LocalAISettings.ControlDraft(enabled: false, backend: .custom, addressText: bad,
                                                      model: "other", minInterval: 30, automaticChecks: false)
        guard case .disable(let off) = s.readControls(turningOff) else {
            Issue.record("turning AI off must apply even when the address is not local")
            return
        }
        #expect(off.enabled == false)
        #expect(off.backend == .custom && off.baseURL == url && off.model == "qwen")
        #expect(off.minInterval == 90 && off.automaticChecks && off.pauseDelay == 7 && off.timeout == 11 && off.minIdle == 3)
        #expect(s == LocalAISettings(enabled: true, backend: .custom, baseURL: url, model: "qwen",
                                     minInterval: 90, pauseDelay: 7, timeout: 11, minIdle: 3, automaticChecks: true))

        let intervalOnly = LocalAISettings.ControlDraft(enabled: true, backend: .custom, addressText: bad,
                                                        model: "other", minInterval: 30, automaticChecks: false)
        #expect(s.readControls(intervalOnly) == .invalidAddress)
        #expect(s.readControls(LocalAISettings.ControlDraft(enabled: true, backend: .custom, addressText: "8.8.8.8:1234",
                                                           model: "qwen", minInterval: 90, automaticChecks: true)) == .invalidAddress)
        #expect(s.readControls(LocalAISettings.ControlDraft(enabled: true, backend: .custom, addressText: "",
                                                           model: "qwen", minInterval: 90, automaticChecks: true)) == .invalidAddress)
        var alreadyOff = s
        alreadyOff.enabled = false
        #expect(alreadyOff.readControls(LocalAISettings.ControlDraft(enabled: true, backend: .custom, addressText: bad,
                                                                     model: nil, minInterval: 30, automaticChecks: true)) == .invalidAddress)

        guard case .apply(let moved) = s.readControls(LocalAISettings.ControlDraft(
            enabled: true, backend: .custom, addressText: "10.0.0.5:8080", model: nil, minInterval: 30, automaticChecks: false))
        else { Issue.record("a local address applies"); return }
        #expect(moved.baseURL.absoluteString == "http://10.0.0.5:8080/v1")
        #expect(moved.model == nil && moved.minInterval == 30 && moved.automaticChecks == false)
        #expect(moved.pauseDelay == 7 && moved.timeout == 11 && moved.minIdle == 3)

        // Not Custom: the address field is the preset's, and a garbage string doesn't block the change.
        guard case .apply(let ollama) = s.readControls(LocalAISettings.ControlDraft(
            enabled: true, backend: .ollama, addressText: bad, model: "m", minInterval: 60, automaticChecks: true))
        else { Issue.record("leaving Custom applies"); return }
        #expect(ollama.backend == .ollama)
        #expect(ollama.baseURL.absoluteString == "http://localhost:11434/v1")
        #expect(ollama.model == "m" && ollama.minInterval == 60)

        let lm = LocalAISettings(enabled: true, backend: .lmStudio, model: "qwen", minInterval: 90, automaticChecks: true)
        #expect(lm.readControls(LocalAISettings.ControlDraft(enabled: true, backend: .custom, addressText: bad,
                                                            model: "qwen", minInterval: 90, automaticChecks: true)) == .invalidAddress)
        #expect(lm.backend == .lmStudio)
    }
}

/// A provider that answers after `delay` (real time) with one hint at
/// `range` in the context text, or hangs until cancelled.
final class SlowProvider: OwlHintProvider, @unchecked Sendable {
    let name: String
    let delay: TimeInterval
    private let lock = NSLock()
    private var _calls = 0
    init(name: String = "local:test-qwen", delay: TimeInterval = 0.05) { self.name = name; self.delay = delay }
    var calls: Int { lock.withLock { _calls } }

    func hints(for context: OwlContext) async -> [OwlHint] {
        lock.withLock { _calls += 1 }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
        if Task.isCancelled { return [] }
        let r = (context.text as NSString).range(of: "<=")
        return [OwlHint(id: "ai-\(context.editGeneration)", kind: .fix, title: "Off by one",
                        range: r.location == NSNotFound ? nil : r, replacement: "<", source: name)]
    }
}

@MainActor
@Suite(.serialized) struct BridgeTests {
    @MainActor final class Rig {
        let registry = OwlProviderRegistry()
        let bridge: LocalAIOwlBridge
        let factoryBox = Box(0)
        var thinking: [(UUID, Bool)] = []
        var hints: [(OwlContext, [OwlHint])] = []

        init(provider: (any OwlHintProvider)?) {
            let box = factoryBox
            bridge = LocalAIOwlBridge(registry: registry, makeProvider: { _ in box.mutate { $0 += 1 }; return provider })
            bridge.onThinking = { [unowned self] id, on in thinking.append((id, on)) }
            bridge.onHints = { [unowned self] c, h in hints.append((c, h)) }
        }
    }

    static let fast = LocalAISettings(enabled: true, backend: .lmStudio, model: "test-qwen", minInterval: 0.1, pauseDelay: 0.05, timeout: 0.5, minIdle: 0,
                                      automaticChecks: true)

    @Test func disabledRegistersNothingAndNeverAsks() async {
        let rig = Rig(provider: SlowProvider())
        await rig.bridge.apply(.default)
        #expect(rig.factoryBox.value == 0)
        #expect(!rig.registry.hasAIProvider)
        #expect(!rig.bridge.isActive)
    }

    @Test func enabledRegistersAnAIEntryThatAnswersNothing() async {
        let provider = SlowProvider()
        let rig = Rig(provider: provider)
        await rig.bridge.apply(Self.fast)
        #expect(rig.registry.hasAIProvider)
        #expect(rig.bridge.providerName == "local:test-qwen")
        #expect(rig.registry.entries.map(\.provider.name) == ["local:test-qwen"])
        // The coordinator's own query never reaches the model.
        let (bridgeDefaults, bridgeSuite) = TestDefaults.make("cedric-bridge-")
        defer { TestDefaults.remove(bridgeSuite) }
        let coordinator = OwlCoordinator(registry: rig.registry, defaults: bridgeDefaults)
        coordinator.source = .rulesAndAI
        for p in rig.registry.providers(for: .rulesAndAI) { #expect(await p.hints(for: context()).isEmpty) }
        #expect(provider.calls == 0)
        // Off again: unregistered.
        var off = Self.fast; off.enabled = false
        await rig.bridge.apply(off)
        #expect(!rig.registry.hasAIProvider)
        #expect(!rig.bridge.isActive)
    }

    @Test func refusesPublicEndpointsAndMissingModels() async {
        let rig = Rig(provider: SlowProvider())
        var s = Self.fast
        s.baseURL = URL(string: "https://api.example.com/v1")!
        await rig.bridge.apply(s)
        #expect(!rig.registry.hasAIProvider)
        #expect(rig.factoryBox.value == 0)
        #expect(rig.bridge.lastProblem != nil)
        let none = Rig(provider: nil)
        await none.bridge.apply(Self.fast)
        #expect(!none.registry.hasAIProvider)
        #expect(none.bridge.lastProblem != nil)
    }

    @Test func editThinksThenDeliversThenStopsThinking() async {
        let rig = Rig(provider: SlowProvider(delay: 0.1))
        await rig.bridge.apply(Self.fast)
        let doc = UUID()
        let text = "for i in 0...n {\n  if i <= items.count { }\n}\n"
        let ctx = OwlContext(fileName: "a.swift", language: "swift", text: text, textStart: 5000,
                             visibleRange: NSRange(location: 0, length: 10), selection: nil, documentID: doc, editGeneration: 3)
        rig.bridge.contextChanged(ctx)
        #expect(await eventually { @MainActor in rig.thinking.count == 2 })
        #expect(rig.thinking.map(\.1) == [true, false])
        #expect(rig.thinking.allSatisfy { $0.0 == doc })
        #expect(rig.hints.count == 1)
        let (c, h) = rig.hints[0]
        #expect(c.textStart == 5000 && c.editGeneration == 3)
        #expect(h.first?.source == "local:test-qwen")
        let docRange = h.first.flatMap { OwlCoordinator.documentRange($0, context: c) }
        #expect(docRange == NSRange(location: 5000 + (text as NSString).range(of: "<=").location, length: 2))
        #expect(rig.bridge.thinking.isEmpty)
    }

    @Test func timeoutGoesBackToIdleWithoutHints() async {
        let rig = Rig(provider: SlowProvider(delay: 5))
        var s = Self.fast; s.timeout = 0.2
        await rig.bridge.apply(s)
        rig.bridge.contextChanged(context(gen: 1))
        #expect(await eventually { @MainActor in rig.thinking.count == 2 })
        #expect(rig.thinking.map(\.1) == [true, false])
        #expect(rig.hints.isEmpty)
    }

    @Test func pausedOrInactiveNeverAsks() async {
        let provider = SlowProvider()
        let rig = Rig(provider: provider)
        await rig.bridge.apply(Self.fast)
        rig.bridge.setPaused(true)          // source back to Rules
        rig.bridge.contextChanged(context(gen: 1))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(provider.calls == 0)
        rig.bridge.setPaused(false)
        rig.bridge.setAppActive(false)
        rig.bridge.contextChanged(context(gen: 2))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(provider.calls == 0)
        rig.bridge.setAppActive(true)
        #expect(await eventually { provider.calls == 1 })
    }

    @Test func turningOffMidRequestClearsThinking() async {
        let rig = Rig(provider: SlowProvider(delay: 5))
        await rig.bridge.apply(Self.fast)
        rig.bridge.contextChanged(context(gen: 1))
        #expect(await eventually { @MainActor in rig.thinking.count == 1 })
        var off = Self.fast; off.enabled = false
        await rig.bridge.apply(off)
        #expect(rig.thinking.map(\.1) == [true, false])
        #expect(rig.bridge.thinking.isEmpty)
    }

    @Test func realFactoryAutoPicksFromTheServer() async {
        let server = StubServer()
        server.json("/v1/models", ["data": [["id": "qwen/qwen3.8-27b"], ["id": "qwen2.5-coder-1.5b-instruct-mlx"],
                                            ["id": "qwen2.5-coder-3b-instruct"]]])
        let registry = OwlProviderRegistry()
        let session = server.session
        let bridge = LocalAIOwlBridge(registry: registry, makeProvider: { await LocalAIOwl.makeProvider(settings: $0, session: session) })
        var s = LocalAISettings(enabled: true, backend: .custom, baseURL: server.baseURL)
        await bridge.apply(s)
        #expect(bridge.providerName == "local:qwen2.5-coder-3b-instruct")
        s.model = "qwen2.5-coder-1.5b-instruct-mlx"
        await bridge.apply(s)
        #expect(registry.entries.map(\.provider.name) == ["local:qwen2.5-coder-1.5b-instruct-mlx"])
    }

    /// Interval and automatic checks retune the scheduler. They must not
    /// rebuild the provider or cancel a check that's already running.
    @Test func intervalOrAutomaticChangeKeepsTheProviderAndTheCheck() async {
        let provider = SlowProvider(delay: 0.4)
        let rig = Rig(provider: provider)
        await rig.bridge.apply(Self.fast)
        let running = rig.bridge.scheduler
        let doc = UUID()
        #expect(rig.bridge.checkNow(context("if i <= n { print(indexValue) }", gen: 1, doc: doc)))
        #expect(await eventually { @MainActor in rig.bridge.thinking.contains(doc) })
        var tweaked = Self.fast
        tweaked.minInterval = 30
        tweaked.automaticChecks = false
        tweaked.pauseDelay = 2
        tweaked.timeout = 8
        tweaked.minIdle = 1
        await rig.bridge.apply(tweaked)
        #expect(rig.factoryBox.value == 1)
        #expect(rig.bridge.scheduler === running)
        #expect(rig.bridge.providerName == "local:test-qwen")
        #expect(rig.bridge.thinking.contains(doc))
        let config = await rig.bridge.scheduler?.config
        #expect(config?.minInterval == 30 && config?.automatic == false)
        #expect(config?.pauseDelay == 2 && config?.timeout == 8 && config?.minIdle == 1)
        #expect(await eventually { @MainActor in rig.hints.first?.1.first?.title == "Off by one" })
        #expect(provider.calls == 1)
    }

    /// A new backend, model or address rebuilds the provider (and, with no
    /// model chosen, asks the server for its list). The schedule does not.
    @Test func backendModelOrAddressChangesRebuildTheProvider() async {
        let server = StubServer()
        server.json("/v1/models", ["data": [["id": "qwen/qwen3.8-27b"], ["id": "qwen2.5-coder-1.5b-instruct-mlx"],
                                            ["id": "qwen2.5-coder-3b-instruct"]]])
        let registry = OwlProviderRegistry()
        let calls = Box(0)
        let session = server.session
        let bridge = LocalAIOwlBridge(registry: registry, makeProvider: { s in
            calls.mutate { $0 += 1 }
            return await LocalAIOwl.makeProvider(settings: s, session: session)
        })
        func modelHits() -> Int { server.recorded.filter { $0.path == "/v1/models" }.count }
        var s = LocalAISettings(enabled: true, backend: .custom, baseURL: server.baseURL, minInterval: 90, automaticChecks: true)
        await bridge.apply(s)
        #expect(calls.value == 1 && modelHits() == 1)
        #expect(bridge.providerName == "local:qwen2.5-coder-3b-instruct")
        let first = bridge.scheduler

        s.minInterval = 30
        s.automaticChecks = false
        await bridge.apply(s)
        #expect(calls.value == 1 && modelHits() == 1)
        #expect(bridge.scheduler === first)
        #expect(await bridge.scheduler?.config.minInterval == 30)
        #expect(await bridge.scheduler?.config.automatic == false)

        s.model = "qwen2.5-coder-1.5b-instruct-mlx"
        await bridge.apply(s)
        #expect(calls.value == 2 && modelHits() == 1)
        #expect(bridge.providerName == "local:qwen2.5-coder-1.5b-instruct-mlx")
        #expect(bridge.scheduler !== first)

        s.baseURL = URL(string: "http://127.0.0.1:\(server.port)/v1")!
        await bridge.apply(s)
        #expect(calls.value == 3 && modelHits() == 1)

        s.backend = .ollama
        s.baseURL = server.baseURL
        s.model = nil
        await bridge.apply(s)
        #expect(calls.value == 4 && modelHits() == 2)
        #expect(bridge.providerName == "local:qwen2.5-coder-3b-instruct")
    }
}

@Suite struct EngineAndPromptTests {
    @Test func enginesForEachPlace() async {
        var s = LocalAISettings(enabled: true)
        s.backend = .builtIn
        let built = AIEngines.engine(for: s)
        #expect(built.isAvailable && built.unavailableReason == nil && !built.needsAddress)
        s.backend = .apple
        let apple = AIEngines.engine(for: s)
        #expect(!apple.needsAddress)
        #expect(apple.isAvailable == AppleFoundationModelsProvider.isAvailable)
        for b in [LocalAISettings.Backend.lmStudio, .ollama, .custom] {
            s.backend = b
            #expect(AIEngines.engine(for: s).needsAddress && AIEngines.engine(for: s).isAvailable)
        }
    }

    @MainActor @Test func bridgeExplainsUnavailableEngine() async {
        let registry = OwlProviderRegistry()
        let bridge = LocalAIOwlBridge(registry: registry, makeProvider: { _ in nil })
        await bridge.apply(LocalAISettings(enabled: true, backend: .builtIn))
        #expect(!registry.hasAIProvider)
        #expect(bridge.lastProblem?.contains("No model downloaded") == true)
        await bridge.apply(LocalAISettings(enabled: true, backend: .lmStudio))
        #expect(bridge.lastProblem?.contains("start the server") == true)
    }

    @Test func everyEngineSharesTheOwlPrompts() {
        let msgs = HintPrompt.messages(for: context("let x = 1"), text: "let x = 1", model: "qwen3-4b")
        #expect(msgs[0].content == OwlPrompts.system(for: .codeHints))
        #expect(msgs[0].content.hasPrefix(OwlPrompts.persona))
        #expect(msgs[0].content.contains("Cedric"))
        #expect(msgs[1].content.hasSuffix("/no_think"))
    }
}
