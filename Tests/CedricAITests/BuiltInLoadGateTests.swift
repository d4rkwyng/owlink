import Foundation
import Testing
@testable import CedricAI
import CedricCore

// The freeze: with Built-in, automatic checks on and "Rules + AI", the
// automatic owl-hint check made the first in-process load of Qwen3 4B
// about ten seconds after a file was opened, and the GPU hung. These tests
// are the proof that path is closed: opening, saving, scrolling and idling
// never load the built-in model; only an explicit request or the
// "Load model at launch" opt-in does, and a load that hangs is given up on.

/// A runtime whose load can hang the way a stuck Metal load does: it
/// ignores cancellation (only records it) until `release()`.
final class HangingRuntime: BuiltInRuntime, @unchecked Sendable {
    let fake = FakeRuntime()
    let attempts = Box(0)
    let cancelRequests = Box(0)
    /// Loads that ran on the main thread (must stay 0).
    let mainThreadLoads = Box(0)
    private let lock = NSLock()
    private var hanging = true
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(hanging: Bool = true) { self.hanging = hanging }

    /// Lets every waiting load finish; later loads don't hang.
    func release() {
        let w: [CheckedContinuation<Void, Never>] = lock.withLock { hanging = false; defer { waiters = [] }; return waiters }
        w.forEach { $0.resume() }
    }

    /// Later loads hang again.
    func hangAgain() { lock.withLock { hanging = true } }

    func load(modelAt url: URL) async throws -> any LoadedModel {
        attempts.mutate { $0 += 1 }
        if pthread_main_np() != 0 { mainThreadLoads.mutate { $0 += 1 } }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                let wait: Bool = lock.withLock { if hanging { waiters.append(c) }; return hanging }
                if !wait { c.resume() }
            }
        } onCancel: { [cancelRequests] in
            cancelRequests.mutate { $0 += 1 }
        }
        return FakeRuntime.Model(path: url, runtime: fake)
    }
}

/// An installed built-in model on `host`.
private func builtIn(_ host: BuiltInModelHost) throws -> (BuiltInEngine, BuiltInModel) {
    let dir = tempDir()
    let store = ModelStore(directory: dir)
    let model = testModel(body: Data(), sha: String(repeating: "c", count: 64), size: 4096)
    try store.prepare()
    FileManager.default.createFile(atPath: store.fileURL(for: model).path, contents: Data(count: 4096))
    try model.sha256.write(to: store.markerURL(for: model), atomically: true, encoding: .utf8)
    return (BuiltInEngine(catalog: ModelCatalog(models: [model]), store: store, host: host), model)
}

@Suite struct LoadModelAtLaunchSettingTests {
    @Test func offByDefaultAndForOldSavedSettings() throws {
        #expect(LocalAISettings().loadModelAtLaunch == false)
        #expect(LocalAISettings.default.loadModelAtLaunch == false)
        // Derek's saved settings, from before the key existed.
        let old = #"{"enabled":true,"backend":"builtIn","baseURL":"http:\/\/localhost:1234\/v1","minInterval":90,"pauseDelay":5,"timeout":20,"minIdle":10,"automaticChecks":true}"#
        let s = try JSONDecoder().decode(LocalAISettings.self, from: Data(old.utf8))
        #expect(s.enabled && s.backend == .builtIn && s.automaticChecks && s.minIdle == 10)
        #expect(s.loadModelAtLaunch == false)
        // Saved on, read back on.
        var on = s
        on.loadModelAtLaunch = true
        let back = try JSONDecoder().decode(LocalAISettings.self, from: JSONEncoder().encode(on))
        #expect(back.loadModelAtLaunch)
    }

    @Test func theCheckboxIsReadWithTheOtherControls() {
        let s = LocalAISettings(enabled: true, backend: .builtIn)
        let base = LocalAISettings.ControlDraft(enabled: true, backend: .builtIn, addressText: "", model: nil,
                                                minInterval: 90, automaticChecks: true)
        guard case .apply(let same) = s.readControls(base) else { Issue.record("not applied"); return }
        #expect(same.loadModelAtLaunch == false)   // nil in the draft: unchanged
        var draft = base
        draft.loadModelAtLaunch = true
        guard case .apply(let on) = s.readControls(draft) else { Issue.record("not applied"); return }
        #expect(on.loadModelAtLaunch)
        #expect(!LocalAISettings.loadModelAtLaunchNote.isEmpty)
    }
}

@MainActor
@Suite(.serialized) struct BuiltInLoadGateTests {
    /// Derek's settings: built-in, automatic checks on (Apple silicon's
    /// default), the real pause (5 s), idle (10 s) and interval (90 s),
    /// "Load model at launch" left at its default.
    static let dereks = LocalAISettings(enabled: true, backend: .builtIn, minInterval: 90, pauseDelay: 5, minIdle: 10,
                                        automaticChecks: true)

    func bridge(_ host: BuiltInModelHost, clock: FakeClock, settings: LocalAISettings = dereks) async throws -> LocalAIOwlBridge {
        let (engine, _) = try builtIn(host)
        let b = LocalAIOwlBridge(registry: OwlProviderRegistry(), clock: clock, power: FakePower(),
                                 engine: { _ in engine }, makeProvider: { _ in await engine.makeProvider(model: nil) })
        await b.apply(settings)
        return b
    }

    /// Advances virtual time in steps, letting each armed timer fire.
    func pass(_ seconds: TimeInterval, _ clock: FakeClock, step: TimeInterval = 1) async {
        var t: TimeInterval = 0
        while t < seconds {
            clock.advance(step)
            t += step
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    @Test func openingAFileAndIdlingNeverLoadsTheBuiltInModel() async throws {
        #expect(Self.dereks.loadModelAtLaunch == false)
        let rt = FakeRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let b = try await bridge(host, clock: clock)
        #expect(b.isActive && b.isAutomatic && !b.isPaused)   // "Rules + AI", automatic
        #expect(b.preloadsStarted == 0)
        #expect(!b.automaticAllowedNow)
        let doc = UUID()
        // Open.
        b.contextChanged(context(gen: 1, doc: doc))
        #expect(await eventually { clock.pendingSleepers >= 1 })
        await pass(15, clock)                       // past minIdle and pauseDelay
        #expect(await eventually { await b.scheduler?.gatedAutomatic ?? 0 >= 1 })
        // Save (a new generation), scroll (same generation), idle on.
        b.contextChanged(context("let value = items.count + 2", gen: 2, doc: doc))
        await pass(15, clock)
        b.contextChanged(context("let value = items.count + 2", gen: 2, doc: doc))
        await pass(100, clock, step: 5)             // past minInterval
        // Switch away and back.
        b.setAppActive(false)
        b.setAppActive(true)
        await pass(100, clock, step: 5)
        #expect(await eventually { await b.scheduler?.gatedAutomatic ?? 0 >= 2 })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rt.loads.value.isEmpty, "the model was never loaded")
        #expect(await host.loadAttempts == 0)
        #expect(await host.refusedAutomatic == 0, "the provider was not even asked")
        #expect(rt.requests.value.isEmpty)
        #expect(await b.scheduler?.requestCount == 0)
        #expect(b.thinking.isEmpty)
        #expect(b.lastCheck == nil)                 // no failed check to report
        #expect(b.statusLine() == "Built-in · automatic hints start after you ask Cedric")
        // Even a direct automatic request (a path that forgot to ask the
        // gate) can't make the first load.
        let path = URL(fileURLWithPath: "/tmp/direct.gguf")
        await #expect(throws: BuiltInError.automaticLoadNotAllowed) {
            _ = try await host.generate(modelAt: path, GenerationRequest(system: "s", user: "u"))
        }
        #expect(rt.loads.value.isEmpty)
        #expect(await host.loadAttempts == 0)
    }

    @Test func afterTheUserAsksAutomaticChecksMayUseTheModel() async throws {
        let rt = FakeRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        var fast = Self.dereks
        fast.minInterval = 0.1; fast.pauseDelay = 0.05; fast.minIdle = 0
        let b = try await bridge(host, clock: clock, settings: fast)
        let doc = UUID()
        // Ask AI Now: loads.
        #expect(b.checkNow(context(gen: 1, doc: doc)))
        #expect(await eventually { rt.loads.value.count == 1 && rt.requests.value.count == 1 })
        #expect(host.session.explicitlyLoaded)
        #expect(await eventually { await MainActor.run { b.lastCheck != nil } })
        #expect(b.automaticAllowedNow)
        // Now an edit and a pause: an automatic check, same loaded model.
        b.contextChanged(context("let value = items.count + 3", gen: 2, doc: doc))
        await pass(2, clock, step: 0.1)
        #expect(await eventually { rt.requests.value.count == 2 })
        #expect(rt.loads.value.count == 1)
        // Closing the document doesn't forget the session.
        b.documentClosed(doc)
        #expect(host.session.allowsAutomatic)
        // The auto-review cap still applies to automatic checks.
        let big = UUID()
        b.setAutoReviewCapped(big, true)
        b.contextChanged(context(gen: 1, doc: big))
        await pass(2, clock, step: 0.1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rt.requests.value.count == 2)
    }

    /// After the user's load is unloaded for idleness, automatic checks
    /// (open, edit, idle) never load it again; the next request the user
    /// makes, or the launch opt-in, does.
    @Test func afterAnIdleUnloadAutomaticChecksDoNotReload() async throws {
        let rt = FakeRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        var fast = Self.dereks
        fast.minInterval = 0.1; fast.pauseDelay = 0.05; fast.minIdle = 0
        let b = try await bridge(host, clock: clock, settings: fast)
        let doc = UUID()
        // Ask AI Now: loads.
        #expect(b.checkNow(context(gen: 1, doc: doc)))
        #expect(await eventually { rt.loads.value.count == 1 && rt.requests.value.count == 1 })
        #expect(await eventually { await MainActor.run { b.lastCheck != nil } })
        #expect(b.automaticAllowedNow)
        let path = try #require(await host.loadedPath)
        // Idle past the timeout: unloaded.
        await pass(BuiltInModelHost.defaultIdleTimeout + 10, clock, step: 5)
        #expect(await eventually { await host.loadedPath == nil })
        #expect(rt.unloaded.value.count == 1)
        #expect(host.session.explicitlyLoaded && !host.session.modelInMemory)
        #expect(!b.automaticAllowedNow)
        // Open another file, edit, idle: gated, no load, no request.
        let gatedBefore = await b.scheduler?.gatedAutomatic ?? 0
        let other = UUID()
        b.contextChanged(context(gen: 1, doc: other))
        await pass(2, clock, step: 0.1)
        b.contextChanged(context("let value = items.count + 4", gen: 2, doc: doc))
        await pass(30, clock, step: 1)
        #expect(await eventually { await b.scheduler?.gatedAutomatic ?? 0 > gatedBefore })
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rt.loads.value.count == 1, "automatic checks did not reload the model")
        #expect(rt.requests.value.count == 1)
        // Even a direct automatic request (past the scheduler's gate) is
        // refused without loading.
        await #expect(throws: BuiltInError.automaticLoadNotAllowed) {
            _ = try await host.generate(modelAt: path, GenerationRequest(system: "s", user: "u"))
        }
        #expect(rt.loads.value.count == 1)
        // The user asks again: loads again, and automatic may use it.
        #expect(b.checkNow(context("let value = items.count + 5", gen: 3, doc: doc)))
        #expect(await eventually { rt.loads.value.count == 2 })
        #expect(b.automaticAllowedNow)
        // The launch opt-in may load after an idle unload too.
        await host.unload()
        try await host.preload(modelAt: path)
        #expect(rt.loads.value.count == 3)
    }

    @Test func applyingSettingsLoadsNothingUnlessLoadAtLaunchIsOn() async throws {
        let rt = HangingRuntime(hanging: false), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let b = try await bridge(host, clock: clock)
        // Settings applied and AI on, with the option off: nothing loads.
        var again = Self.dereks
        again.minInterval = 60
        await b.apply(again)
        try? await Task.sleep(nanoseconds: 200_000_000)
        #expect(rt.attempts.value == 0)
        #expect(b.preloadsStarted == 0)
        // Turned on in Settings: loads now, in the background.
        var on = again
        on.loadModelAtLaunch = true
        await b.apply(on)
        #expect(b.preloadsStarted == 1)
        #expect(await eventually { await host.loadCount == 1 })
        #expect(rt.mainThreadLoads.value == 0)
        #expect(host.session.allowsAutomatic)
        #expect(b.automaticAllowedNow)
        // Already loaded: applying again doesn't load again.
        await b.apply(Self.dereks)
        await b.apply(on)
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(rt.attempts.value == 1)
    }

    @Test func loadAtLaunchDoesNotWaitForTheLoadAndIsWatchdogged() async throws {
        let rt = HangingRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        var on = Self.dereks
        on.loadModelAtLaunch = true
        // The launch apply returns (the window opens) while the load hangs.
        let b = try await bridge(host, clock: clock, settings: on)
        #expect(b.isActive && b.preloadsStarted == 1)
        #expect(await eventually { rt.attempts.value == 1 })
        #expect(rt.mainThreadLoads.value == 0)
        #expect(!b.automaticAllowedNow)
        // The watchdog fires: unhealthy, automatic stays rules-only.
        #expect(await eventually { clock.pendingSleepers >= 1 })
        clock.advance(BuiltInWatchdog.seconds + 1)
        #expect(await eventually { host.session.unhealthy != nil })
        #expect(b.engineUnhealthy && !b.automaticAllowedNow)
        #expect(b.statusLine() == "Built-in · didn’t finish loading · automatic AI is off")
        let doc = UUID()
        b.contextChanged(context(gen: 1, doc: doc))
        await pass(120, clock, step: 5)
        #expect(await eventually { await b.scheduler?.gatedAutomatic ?? 0 >= 1 })
        #expect(rt.attempts.value == 1)
        #expect(await b.scheduler?.requestCount == 0)
        rt.release()
    }
}

@Suite(.serialized) struct BuiltInWatchdogTests {
    let path = URL(fileURLWithPath: "/tmp/hang.gguf")
    let req = GenerationRequest(system: "s", user: "u")

    @Test func theLimitIsOneConstantAndCoversIntel() {
        #expect(BuiltInWatchdog.seconds == 60)
        #expect(BuiltInModelHost(runtime: FakeRuntime()).loadTimeout == BuiltInWatchdog.seconds)
    }

    /// A load (or its warm-up first decode, which `LlamaRuntime.load` runs
    /// inside the load) that doesn't return: the engine is marked unhealthy,
    /// a notice is posted, the stuck load is asked to stop, nothing waits
    /// for it, and automatic paths never call load again.
    @Test func aHungLoadMarksTheEngineUnhealthyAndAutomaticPathsStopLoading() async throws {
        let rt = HangingRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let notices = Box(0)
        let token = NotificationCenter.default.addObserver(forName: .cedricBuiltInModelUnhealthy, object: nil, queue: nil) { n in
            if n.userInfo?["seconds"] as? Int == Int(BuiltInWatchdog.seconds) { notices.mutate { $0 += 1 } }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        let ask = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) } }
        #expect(await eventually { rt.attempts.value == 1 && clock.pendingSleepers >= 1 })
        clock.advance(BuiltInWatchdog.seconds - 1)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(host.session.unhealthy == nil)        // not yet
        clock.advance(2)
        await #expect(throws: BuiltInError.loadTimedOut(seconds: Int(BuiltInWatchdog.seconds))) { try await ask.value }
        #expect(host.session.unhealthy == BuiltInSession.Unhealthy(seconds: Int(BuiltInWatchdog.seconds)))
        #expect(!host.session.allowsAutomatic)
        #expect(await eventually { notices.value == 1 })
        #expect(await eventually { rt.cancelRequests.value == 1 }, "the stuck load was asked to stop")
        #expect(await host.hasStuckLoad)
        // Automatic: refused, no load.
        for _ in 0..<3 {
            await #expect(throws: BuiltInError.unhealthy) { _ = try await host.generate(modelAt: path, req) }
        }
        // Explicit, while the stuck load still runs: no second load, and
        // the user is told it is still loading (the retry is kept).
        for _ in 0..<2 {
            await #expect(throws: BuiltInError.stillLoading) {
                _ = try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) }
            }
        }
        #expect(rt.attempts.value == 1)
        #expect(await host.loadAttempts == 1)
        // The stuck load finishes after all: freed, not used.
        rt.release()
        #expect(await eventually { await !host.hasStuckLoad })
        #expect(rt.fake.unloaded.value == ["hang.gguf"])
        #expect(await host.loadedPath == nil)
        // Still unhealthy: automatic paths never retry.
        await #expect(throws: BuiltInError.unhealthy) { _ = try await host.generate(modelAt: path, req) }
        #expect(rt.attempts.value == 1)
        // Now that it has stopped, the user's one retry is still there
        // (asking while it was stuck didn't use it up).
        _ = try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) }
        #expect(rt.attempts.value == 2)
        #expect(host.session.unhealthy == nil)
    }

    @Test func theUserMayRetryOnceStillWatchdogged() async throws {
        let rt = HangingRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let first = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) } }
        #expect(await eventually { clock.pendingSleepers >= 1 })
        clock.advance(BuiltInWatchdog.seconds + 1)
        _ = try? await first.value
        rt.release()
        #expect(await eventually { await !host.hasStuckLoad })
        // The retry hangs too.
        rt.hangAgain()
        let retry = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) } }
        #expect(await eventually { rt.attempts.value == 2 && clock.pendingSleepers >= 1 })
        clock.advance(BuiltInWatchdog.seconds + 1)
        await #expect(throws: BuiltInError.loadTimedOut(seconds: Int(BuiltInWatchdog.seconds))) { try await retry.value }
        rt.release()
        #expect(await eventually { await !host.hasStuckLoad })
        // No third load this session, even asked.
        await #expect(throws: BuiltInError.unhealthy) {
            _ = try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) }
        }
        #expect(rt.attempts.value == 2)
    }

    @Test func aRetryThatLoadsMakesTheEngineHealthyAgain() async throws {
        let rt = HangingRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let first = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) } }
        #expect(await eventually { clock.pendingSleepers >= 1 })
        clock.advance(BuiltInWatchdog.seconds + 1)
        _ = try? await first.value
        rt.release()
        #expect(await eventually { await !host.hasStuckLoad })
        _ = try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) }
        #expect(host.session.unhealthy == nil)
        #expect(host.session.allowsAutomatic)
        #expect(await host.loadedPath == path)
        // Automatic use of the loaded model now works.
        _ = try await host.generate(modelAt: path, req)
        #expect(rt.attempts.value == 2)
    }

    @Test func aHealthyLoadIsNotCutShort() async throws {
        let rt = FakeRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        _ = try await BuiltInLoad.userAsked { try await host.generate(modelAt: path, req) }
        clock.advance(BuiltInWatchdog.seconds * 2)
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(host.session.unhealthy == nil)
        #expect(await host.loadedPath == path)
        #expect(rt.unloaded.value.isEmpty)
    }
}

/// One load at a time, across models. Before 0.5.4 a request for model B
/// while model A was still loading started a second load: if both
/// finished, B's publication dropped A without unloading it (llama.cpp's
/// exit registry still held it); if both hung, each replaced the
/// watchdog's record of the stuck load, and either finishing cleared it
/// while the other still ran.
@Suite(.serialized) struct BuiltInLoadSerialTests {
    let a = URL(fileURLWithPath: "/tmp/serial-a.gguf"), b = URL(fileURLWithPath: "/tmp/serial-b.gguf")
    let req = GenerationRequest(system: "s", user: "u")

    @Test func anotherModelWaitsForTheLoadUnderWayThenSwapsItOut() async throws {
        let rt = HangingRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let (a, b, req) = (a, b, req)
        let first = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: a, req) } }
        #expect(await eventually { rt.attempts.value == 1 })
        // Released on every path, so a failed expectation can't leave a
        // request waiting on the fake load.
        defer { rt.release() }
        let second = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: b, req) } }
        // The second request has reached the gate (not just had time to).
        #expect(await eventually { await host.waitingRequests == 1 })
        #expect(rt.attempts.value == 1, "no second load while the first is in flight")
        #expect(await host.loadAttempts == 1)
        rt.release()
        _ = try await first.value
        _ = try await second.value
        #expect(rt.attempts.value == 2)
        #expect(await host.loadedPath == b)
        #expect(rt.fake.unloaded.value == ["serial-a.gguf"], "the first model was unloaded, not dropped")
        #expect(await host.loadCount == 2)
        #expect(await host.unloadCount == 1)
        #expect(host.session.unhealthy == nil)
    }

    @Test func anotherModelDuringAHungLoadStartsNothingAndTheStuckRecordHolds() async throws {
        let rt = HangingRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let (a, b, req) = (a, b, req)
        let first = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: a, req) } }
        #expect(await eventually { rt.attempts.value == 1 && clock.pendingSleepers >= 1 })
        defer { rt.release() }
        let second = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: b, req) } }
        // The second request is waiting on the first load before the
        // watchdog fires (a sleep here let it race the clock).
        #expect(await eventually { await host.waitingRequests == 1 })
        #expect(rt.attempts.value == 1, "no second load while the first is in flight")
        clock.advance(BuiltInWatchdog.seconds + 1)
        await #expect(throws: BuiltInError.loadTimedOut(seconds: Int(BuiltInWatchdog.seconds))) { try await first.value }
        // The waiting request sees the stuck load: no load of its own, the retry kept.
        await #expect(throws: BuiltInError.stillLoading) { try await second.value }
        #expect(rt.attempts.value == 1)
        #expect(await host.loadAttempts == 1)
        #expect(await host.hasStuckLoad)
        // The stuck load finishes: freed, the record cleared, nothing loaded.
        rt.release()
        #expect(await eventually { await !host.hasStuckLoad })
        #expect(rt.fake.unloaded.value == ["serial-a.gguf"])
        #expect(await host.loadedPath == nil)
        // The user's one retry is still there, for the other model.
        _ = try await BuiltInLoad.userAsked { try await host.generate(modelAt: b, req) }
        #expect(rt.attempts.value == 2)
        #expect(await host.loadedPath == b)
    }

    /// A request generating with model A holds it: a request for model B
    /// waits until A's generation is done, then frees A and loads B. The
    /// fake fails a generation that reaches it after its free, as
    /// LlamaModel does (the free runs first on llama.cpp's queue:
    /// `notInstalled`). Before the fix, B freed A at once and A's request
    /// failed.
    @Test func aSwitchWaitsForTheOldModelsGeneration() async throws {
        let rt = StrictRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let (a, b, req) = (a, b, req)
        defer { rt.loadGate.open(); rt.generateGate.open() }
        _ = try await BuiltInLoad.userAsked { try await host.generate(modelAt: a, req) }
        // A's next request is leased and on its way to the queue.
        rt.generateGate.close()
        let useA = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: a, req) } }
        #expect(await eventually { rt.count("gen-start serial-a.gguf") == 2 })
        let toB = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: b, req) } }
        // B's request has reached the host (or, before the fix, freed A
        // and started loading B).
        #expect(await eventually { await host.waitingRequests == 1 || rt.count("load-start serial-b.gguf") == 1 })
        #expect(!rt.events.value.contains("unload serial-a.gguf"), "A freed while a request was using it")
        #expect(rt.count("load-start serial-b.gguf") == 0)
        rt.generateGate.open()
        _ = try await useA.value
        _ = try await toB.value
        #expect(rt.count("gen-freed serial-a.gguf") == 0)
        #expect(rt.order("gen-end serial-a.gguf", before: "unload serial-a.gguf"))
        #expect(rt.order("unload serial-a.gguf", before: "load-start serial-b.gguf"))
        #expect(await host.loadedPath == b)
        #expect(await host.unloadCount == 1)
    }

    /// Codex's ordering: A's request and B's both wait on A's load. When it
    /// ends, B may resume first; it must not free A before A's request has
    /// generated with it.
    @Test func aRequestWaitingOnItsLoadKeepsTheModelForItsGeneration() async throws {
        let rt = StrictRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let (a, b, req) = (a, b, req)
        defer { rt.loadGate.open(); rt.generateGate.open() }
        rt.loadGate.close()
        let useA = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: a, req) } }
        #expect(await eventually { rt.count("load-start serial-a.gguf") == 1 })
        let toB = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: b, req) } }
        #expect(await eventually { await host.waitingRequests == 1 })
        rt.loadGate.open()
        _ = try await useA.value
        _ = try await toB.value
        #expect(rt.count("gen-freed serial-a.gguf") == 0)
        #expect(rt.order("gen-end serial-a.gguf", before: "unload serial-a.gguf"))
        #expect(rt.order("unload serial-a.gguf", before: "load-start serial-b.gguf"))
        #expect(await host.loadedPath == b)
    }

    /// Settings "Unload" during a generation: the model leaves the host at
    /// once (no new request gets it) and is freed when that generation ends.
    @Test func anUnloadDuringAGenerationFreesWhenItEnds() async throws {
        let rt = StrictRuntime(), clock = FakeClock()
        let host = BuiltInModelHost(runtime: rt, clock: clock)
        let (a, req) = (a, req)
        defer { rt.loadGate.open(); rt.generateGate.open() }
        _ = try await BuiltInLoad.userAsked { try await host.generate(modelAt: a, req) }
        rt.generateGate.close()
        let useA = Task { try await BuiltInLoad.userAsked { try await host.generate(modelAt: a, req) } }
        #expect(await eventually { rt.count("gen-start serial-a.gguf") == 2 })
        await host.unload()
        #expect(await host.loadedPath == nil)
        #expect(rt.count("unload serial-a.gguf") == 0)
        rt.generateGate.open()
        _ = try await useA.value
        #expect(await eventually { rt.count("unload serial-a.gguf") == 1 })
        #expect(rt.order("gen-end serial-a.gguf", before: "unload serial-a.gguf"))
        #expect(rt.count("gen-freed serial-a.gguf") == 0)
    }
}

/// A gate a fake waits at until it is open.
final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool = true) { isOpen = open }
    func close() { lock.withLock { isOpen = false } }
    func open() {
        let w: [CheckedContinuation<Void, Never>] = lock.withLock { isOpen = true; defer { waiters = [] }; return waiters }
        w.forEach { $0.resume() }
    }
    func pass() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let wait: Bool = lock.withLock { if !isOpen { waiters.append(c) }; return !isOpen }
            if !wait { c.resume() }
        }
    }
}

/// Models that fail a generation reaching them after their free, as
/// LlamaModel's does (`run` on a freed context throws `notInstalled`),
/// with gates before the load and before the generation reaches the
/// "queue", and a log of what happened in order.
final class StrictRuntime: BuiltInRuntime, @unchecked Sendable {
    final class Model: LoadedModel, @unchecked Sendable {
        let name: String
        let runtime: StrictRuntime
        let freed = Box(false)
        init(name: String, runtime: StrictRuntime) { self.name = name; self.runtime = runtime }
        func generate(_ request: GenerationRequest) async throws -> GenerationResult {
            runtime.log("gen-start \(name)")
            await runtime.generateGate.pass()
            if freed.value { runtime.log("gen-freed \(name)"); throw BuiltInError.notInstalled }
            runtime.log("gen-end \(name)")
            return GenerationResult(text: #"{"hints":[]}"#)
        }
        func unload() { freed.mutate { $0 = true }; runtime.log("unload \(name)") }
    }
    let events = Box<[String]>([])
    let loadGate = TestGate(), generateGate = TestGate()
    func log(_ e: String) { events.mutate { $0.append(e) } }
    func count(_ e: String) -> Int { events.value.filter { $0 == e }.count }
    /// The last `first` comes before the first `second` (both present).
    func order(_ first: String, before second: String) -> Bool {
        let ev = events.value
        guard let i = ev.lastIndex(of: first), let j = ev.firstIndex(of: second) else { return false }
        return i < j
    }
    func load(modelAt url: URL) async throws -> any LoadedModel {
        log("load-start \(url.lastPathComponent)")
        await loadGate.pass()
        return Model(name: url.lastPathComponent, runtime: self)
    }
}
