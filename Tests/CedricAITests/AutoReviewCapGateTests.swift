import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Over the auto-review cap (`AutoReviewCap`: 100 KB or 2,000 lines) the
/// AI never checks a document on its own: no timer, no request, no model
/// load because it was opened, saved or left idle. Asking (`checkNow`)
/// still works; the app confirms with the user first. Not large mode.
@Suite struct AutoReviewCapGateTests {
    /// A capped document's context: the 8 KB window the owl would send.
    static let windowText = String(repeating: "2026-11-23 12:00:00 [INFO] pwnagotchi: waiting for handshakes\n", count: 100)

    @Test func automaticChecksNeverAskACappedDocument() async {
        let rig = SchedulerTests.Rig(config: .init(minIdle: 10))
        let doc = UUID()
        await rig.scheduler.setAutoReviewCapped(doc, true)
        // Opened, idle, saved, typed in: never armed, never asked.
        await rig.scheduler.contextChanged(context(Self.windowText, gen: 1, doc: doc, language: "plain", file: "pwn.log"))
        #expect(await rig.scheduler.gate(for: doc) == .autoReviewCapped)
        rig.clock.advance(600)
        #expect(await rig.scheduler.timerFired(doc) == .autoReviewCapped)
        await rig.scheduler.contextChanged(context(Self.windowText, gen: 2, doc: doc, language: "plain", file: "pwn.log"))
        await rig.scheduler.setAppActive(false)
        await rig.scheduler.setAppActive(true)
        await rig.scheduler.updateConfig(.init(pauseDelay: 1, minInterval: 1, minIdle: 0))
        rig.clock.advance(600)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.clock.pendingSleepers == 0, "no timer armed at all")
        #expect(rig.provider.calls.isEmpty)
        #expect(await rig.scheduler.requestCount == 0)
    }

    @Test func checkNowStillWorksForACappedDocument() async {
        let rig = SchedulerTests.Rig(config: .init(minIdle: 10))
        let doc = UUID()
        await rig.scheduler.setAutoReviewCapped(doc, true)
        #expect(await rig.scheduler.checkNow(context(Self.windowText, gen: 1, doc: doc, language: "plain")))
        #expect(await eventually { rig.delivered.value == [1] })
        #expect(await rig.scheduler.requestCount == 1)
        // The answer arrived; nothing re-arms afterwards.
        await rig.scheduler.contextChanged(context(Self.windowText + "x", gen: 2, doc: doc, language: "plain"))
        rig.clock.advance(600)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(rig.clock.pendingSleepers == 0)
        #expect(rig.provider.calls == [1])
        // Large mode still wins: never, not even when asked.
        await rig.scheduler.setLargeDocument(doc, true)
        #expect(await rig.scheduler.checkNow(context(Self.windowText, gen: 3, doc: doc)) == false)
    }

    @Test func anEditCancelsAnAskedForCheckOfACappedDocument() async {
        let rig = SchedulerTests.Rig(hang: true, config: .init(minIdle: 0))
        let doc = UUID()
        await rig.scheduler.setAutoReviewCapped(doc, true)
        #expect(await rig.scheduler.checkNow(context(Self.windowText, gen: 1, doc: doc)))
        #expect(await eventually { rig.provider.calls == [1] })
        await rig.scheduler.contextChanged(context(Self.windowText, gen: 2, doc: doc))
        #expect(await eventually { rig.outcomes.value == [.cancelled] })
        rig.clock.advance(600)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls == [1])
    }

    @Test func goingOverTheCapCancelsAndForgetsComingBackUnderAsksAgain() async {
        let rig = SchedulerTests.Rig(hang: true, config: .init(minIdle: 0))
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [1] })
        // A paste takes it over the cap.
        await rig.scheduler.setAutoReviewCapped(doc, true)
        #expect(await eventually { rig.outcomes.value == [.cancelled] })
        await rig.scheduler.contextChanged(context(gen: 2, doc: doc))
        #expect(await rig.scheduler.gate(for: doc) == .autoReviewCapped)
        // Cut back under: automatic again after the pause.
        await rig.scheduler.setAutoReviewCapped(doc, false)
        await rig.scheduler.contextChanged(context(gen: 3, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [1, 3] })
    }

    @Test func otherDocumentsAreUnaffected() async {
        let rig = SchedulerTests.Rig(config: .init(minIdle: 0))
        let big = UUID(), small = UUID()
        await rig.scheduler.setAutoReviewCapped(big, true)
        await rig.scheduler.contextChanged(context(gen: 1, doc: big))
        await rig.scheduler.contextChanged(context(gen: 7, doc: small))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [7] })
        #expect(await rig.scheduler.gate(for: big) == .autoReviewCapped)
    }
}

@MainActor
@Suite(.serialized) struct AutoReviewCapBridgeTests {
    func bridge(_ provider: any OwlHintProvider) -> LocalAIOwlBridge {
        LocalAIOwlBridge(registry: OwlProviderRegistry(), engine: { _ in AppleIntelligenceEngine(status: .available) },
                         makeProvider: { _ in provider })
    }

    static let settings = LocalAISettings(enabled: true, backend: .apple, minInterval: 0.1, pauseDelay: 0.05, minIdle: 0,
                                          automaticChecks: true)

    @Test func automaticBridgeNeverFeedsOrAsksACappedDocument() async {
        let provider = FakeProvider()
        let b = bridge(provider)
        let got = Box(0)
        b.onHints = { _, _ in got.mutate { $0 += 1 } }
        let doc = UUID()
        // Marked before the AI comes on, kept when it does.
        b.setAutoReviewCapped(doc, true)
        await b.apply(Self.settings)
        #expect(b.isActive && b.isAutomatic)
        #expect(await eventually { @MainActor in await b.scheduler?.autoReviewCapped.contains(doc) == true })
        // The popover's status line doesn't promise a check on a pause for it.
        #expect(b.statusLine()?.hasSuffix("waiting for a pause in typing") == true)
        #expect(b.statusLine(autoReviewCapped: true)?.hasSuffix("checks only when you ask") == true)
        #expect(!b.wantsContext(for: doc), "the editor feeds it nothing")
        #expect(b.wantsContext(for: UUID()))
        for g in 1...4 { b.contextChanged(context(AutoReviewCapGateTests.windowText, gen: g, doc: doc, language: "plain")) }
        try? await Task.sleep(nanoseconds: 400_000_000)
        #expect(provider.calls.isEmpty)
        #expect(await b.scheduler?.requestCount == 0, "not counted as a request")
        #expect(b.lastCheck == nil && b.thinking.isEmpty)
        // Asked (after the app's confirmation): one check, delivered.
        #expect(b.checkNow(context(AutoReviewCapGateTests.windowText, gen: 5, doc: doc, language: "plain")))
        #expect(await eventually { @MainActor in got.value == 1 })
        #expect(provider.calls == [5])
        // While it ran it wanted the edits (to cancel on one); now it doesn't again.
        #expect(await eventually { @MainActor in !b.wantsContext(for: doc) })
        b.contextChanged(context(AutoReviewCapGateTests.windowText, gen: 6, doc: doc, language: "plain"))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(provider.calls == [5])
    }

    @Test func capSurvivesSchedulerRebuildsAndLargeModeToggles() async {
        let provider = FakeProvider()
        let b = bridge(provider)
        let doc = UUID()
        await b.apply(Self.settings)
        b.setAutoReviewCapped(doc, true)
        var s = Self.settings
        s.timeout = 1
        s.backend = .apple
        await b.apply(LocalAISettings(enabled: false))
        await b.apply(s)   // a new scheduler
        #expect(await eventually { @MainActor in await b.scheduler?.autoReviewCapped.contains(doc) == true })
        // "Turn On Anyway" for large mode doesn't lift the cap.
        b.setLargeDocument(doc, true)
        b.setLargeDocument(doc, false)
        #expect(b.isAutoReviewCapped(doc))
        b.contextChanged(context(gen: 1, doc: doc))
        try? await Task.sleep(nanoseconds: 300_000_000)
        #expect(provider.calls.isEmpty)
        // Back under the cap: automatic again.
        b.setAutoReviewCapped(doc, false)
        b.contextChanged(context(gen: 2, doc: doc))
        #expect(await eventually { provider.calls == [2] })
        // Closing forgets it.
        b.setAutoReviewCapped(doc, true)
        b.documentClosed(doc)
        #expect(!b.isAutoReviewCapped(doc))
    }

    /// The built-in engine: opening (and editing, and idling on) a capped
    /// document loads no model and runs nothing.
    @Test func openingACappedDocumentDoesNotLoadOrAskAModel() async {
        let rt = FakeRuntime()
        let model = testModel(body: Data("x".utf8))
        let host = BuiltInModelHost(runtime: rt)
        let builtIn = BuiltInHintProvider(model: model, path: URL(fileURLWithPath: "/tmp/capped.gguf"), host: host)
        let b = LocalAIOwlBridge(registry: OwlProviderRegistry(), engine: { _ in AppleIntelligenceEngine(status: .available) },
                                 makeProvider: { _ in builtIn })
        await b.apply(Self.settings)
        #expect(b.isActive)
        let doc = UUID()
        b.setAutoReviewCapped(doc, true)
        for g in 1...3 { b.contextChanged(context(AutoReviewCapGateTests.windowText, gen: g, doc: doc, language: "plain", file: "pwn.log")) }
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(rt.loads.value.isEmpty, "no model loaded")
        #expect(rt.requests.value.isEmpty)
        #expect(await b.scheduler?.requestCount == 0)
        // An uncapped document on the same engine does load it (the rig
        // works), once the user has loaded the model this session
        // (automatic checks never make the first load: BuiltInLoadGateTests).
        host.session.noteExplicitLoadForTesting()
        b.contextChanged(context(gen: 1, doc: UUID()))
        #expect(await eventually { !rt.loads.value.isEmpty })
    }
}
