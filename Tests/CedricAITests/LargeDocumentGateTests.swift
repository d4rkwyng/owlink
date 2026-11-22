import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The AI gates for big documents: no request (and so no model load, for
/// any engine) for a document in large mode, and none until a document has
/// been open and idle for `minIdle`.
@Suite struct LargeDocumentGateTests {
    @Test func largeDocumentsAreNeverAsked() async {
        let rig = SchedulerTests.Rig(config: .init(minIdle: 10))
        let doc = UUID()
        await rig.scheduler.setLargeDocument(doc, true)
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        #expect(await rig.scheduler.gate(for: doc) == .largeDocument)
        rig.clock.advance(600)
        #expect(await rig.scheduler.timerFired(doc) == .largeDocument)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls.isEmpty)
        #expect(await rig.scheduler.requestCount == 0)
    }

    @Test func goingLargeCancelsAndForgets() async {
        let rig = SchedulerTests.Rig(hang: true, config: .init(minIdle: 0))
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [1] })
        await rig.scheduler.setLargeDocument(doc, true)
        #expect(await eventually { rig.outcomes.value == [.cancelled] })
        await rig.scheduler.contextChanged(context(gen: 2, doc: doc))
        #expect(await rig.scheduler.gate(for: doc) == .largeDocument)
        // Back to normal ("Turn On Anyway"): asked again after the pause.
        await rig.scheduler.setLargeDocument(doc, false)
        await rig.scheduler.contextChanged(context(gen: 3, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [1, 3] })
    }

    @Test func waitsUntilOpenAndIdleTenSeconds() async {
        let rig = SchedulerTests.Rig(config: .init(minIdle: 10))
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        #expect(await rig.scheduler.gate(for: doc) == .typing(remaining: 10))
        rig.clock.advance(9.5)
        #expect(await rig.scheduler.gate(for: doc) == .typing(remaining: 0.5))
        // A scroll (same generation) doesn't restart it, an edit does.
        await rig.scheduler.contextChanged(context("other visible text in the window", gen: 1, doc: doc))
        #expect(await rig.scheduler.gate(for: doc) == .typing(remaining: 0.5))
        await rig.scheduler.contextChanged(context(gen: 2, doc: doc))
        #expect(await rig.scheduler.gate(for: doc) == .typing(remaining: 10))
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls.isEmpty)
        rig.clock.advance(10)
        #expect(await rig.scheduler.gate(for: doc) == .fire)
    }

    @MainActor @Test func bridgeKeepsLargeDocumentsAcrossRebuilds() async {
        let registry = OwlProviderRegistry()
        let provider = FakeProvider()
        let bridge = LocalAIOwlBridge(registry: registry, engine: { _ in AppleIntelligenceEngine(status: .available) },
                                      makeProvider: { _ in provider })
        let doc = UUID()
        bridge.setLargeDocument(doc, true)
        var s = LocalAISettings(enabled: true, backend: .apple, minInterval: 0.1, pauseDelay: 0.05, minIdle: 0)
        await bridge.apply(s)
        #expect(bridge.isActive)
        bridge.contextChanged(context(gen: 1, doc: doc))
        s.timeout = 1
        await bridge.apply(s)   // a new scheduler: still large
        bridge.contextChanged(context(gen: 2, doc: doc))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(provider.calls.isEmpty)
        #expect(await bridge.scheduler?.largeDocuments.contains(doc) == true)
    }

    @Test func oldSavedSettingsGetTheIdleGate() throws {
        let old = #"{"enabled":true,"backend":"builtIn","baseURL":"http:\/\/localhost:1234\/v1","minInterval":90,"pauseDelay":5,"timeout":20}"#
        let s = try JSONDecoder().decode(LocalAISettings.self, from: Data(old.utf8))
        #expect(s.minIdle == 10)
        #expect(s.enabled && s.backend == .builtIn)
        let round = try JSONDecoder().decode(LocalAISettings.self, from: JSONEncoder().encode(LocalAISettings(minIdle: 3)))
        #expect(round.minIdle == 3)
    }
}
