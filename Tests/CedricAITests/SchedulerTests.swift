import Foundation
import Testing
@testable import CedricAI
import CedricCore

@Suite struct SchedulerTests {
    struct Rig {
        let clock = FakeClock()
        let power = FakePower()
        let provider: FakeProvider
        let delivered = Box<[Int]>([])
        let outcomes = Box<[OwlScheduler.Outcome]>([])
        let scheduler: OwlScheduler

        init(hang: Bool = false, config: OwlScheduler.Config = .init()) {
            provider = FakeProvider(hang: hang)
            let delivered = self.delivered, outcomes = self.outcomes
            scheduler = OwlScheduler(provider: provider, config: config, clock: clock, power: power,
                                     onOutcome: { _, o in outcomes.mutate { $0.append(o) } },
                                     deliver: { ctx, _ in delivered.mutate { $0.append(ctx.editGeneration) } })
        }

        /// Advance the fake clock once the scheduler's timer is waiting on it.
        func advance(_ dt: TimeInterval, sleepers: Int = 1) async {
            _ = await eventually { clock.pendingSleepers >= sleepers }
            clock.advance(dt)
            await Task.yield()
        }
    }

    /// A new interval or automatic flag retimes the scheduler. It does not
    /// cancel a check that has already started.
    @Test func updateConfigRetimesWithoutCancellingTheCheck() async {
        let rig = Rig(hang: true)
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        #expect(await eventually { rig.clock.pendingSleepers == 1 })
        await rig.scheduler.updateConfig(.init(pauseDelay: 30, minInterval: 90, timeout: 20, automatic: false))
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(rig.clock.pendingSleepers == 0)
        #expect(rig.provider.calls.isEmpty)
        await rig.scheduler.updateConfig(.init(pauseDelay: 1, minInterval: 10, timeout: 20, automatic: true))
        await rig.advance(1)
        #expect(await eventually { rig.provider.calls == [1] })
        #expect(rig.provider.cancellations == 0)
        await rig.scheduler.updateConfig(.init(pauseDelay: 1, minInterval: 30, timeout: 5, automatic: true))
        try? await Task.sleep(nanoseconds: 40_000_000)
        #expect(rig.provider.cancellations == 0)
        #expect(await rig.scheduler.config.minInterval == 30)
        #expect(await rig.scheduler.config.timeout == 5)
        #expect(await rig.scheduler.config.automatic)
    }

    @Test func firesOnlyAfterTypingPauses() async {
        let rig = Rig()
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        #expect(await rig.scheduler.gate(for: doc) == .typing(remaining: 5))
        await rig.advance(4.9)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls.isEmpty)
        // Typing again restarts the pause.
        await rig.scheduler.contextChanged(context(gen: 2, doc: doc))
        await rig.advance(4.9)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls.isEmpty)
        await rig.advance(0.2)
        #expect(await eventually { rig.delivered.value == [2] })
        #expect(rig.provider.calls == [2])
    }

    @Test func throttlesToOncePerIntervalPerDocument() async {
        let rig = Rig()
        let doc = UUID(), other = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.delivered.value == [1] })

        await rig.scheduler.contextChanged(context(gen: 2, doc: doc))
        await rig.advance(5)
        #expect(await eventually { await rig.scheduler.gate(for: doc) == .throttled(remaining: 85) })
        // Another document has its own budget.
        await rig.scheduler.contextChanged(context(gen: 1, doc: other))
        await rig.advance(5, sleepers: 2)
        #expect(await eventually { rig.provider.calls == [1, 1] })

        await rig.advance(80)   // 90 s since the first fire
        #expect(await eventually { rig.provider.calls.count == 3 })
        #expect(rig.provider.calls.last == 2)
        #expect(await rig.scheduler.requestCount == 3)
    }

    @Test func neverReasksTheSameGeneration() async {
        let rig = Rig()
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 7, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.delivered.value == [7] })
        // A scroll: same generation, new visible text.
        await rig.scheduler.contextChanged(context("other text visible in the window", gen: 7, doc: doc))
        rig.clock.advance(500)
        #expect(await rig.scheduler.timerFired(doc) == .alreadyAsked)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls == [7])
    }

    @Test func neverWhileInactive() async {
        let rig = Rig()
        let doc = UUID()
        await rig.scheduler.setAppActive(false)
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(30)
        #expect(await rig.scheduler.gate(for: doc) == .inactive)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls.isEmpty)
        await rig.scheduler.setAppActive(true)
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [1] })
    }

    @Test func powerGates() async {
        let rig = Rig()
        let doc = UUID()
        rig.power.set(PowerState(onBattery: true, batteryPercent: 15, lowPowerMode: false))
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(6)
        #expect(await eventually { rig.clock.pendingSleepers == 1 })   // re-armed for later
        #expect(await rig.scheduler.gate(for: doc) == .power)
        rig.power.set(PowerState(onBattery: true, batteryPercent: 19, lowPowerMode: false))
        #expect(await rig.scheduler.gate(for: doc) == .power)
        rig.power.set(PowerState(onBattery: false, batteryPercent: 15, lowPowerMode: false))   // charging
        #expect(await rig.scheduler.gate(for: doc) == .fire)
        rig.power.set(PowerState(onBattery: false, batteryPercent: nil, lowPowerMode: true))
        #expect(await rig.scheduler.gate(for: doc) == .power)
        rig.power.set(PowerState(onBattery: true, batteryPercent: 20, lowPowerMode: false))
        #expect(await rig.scheduler.gate(for: doc) == .fire)
        #expect(PowerState.mains.allowsChecks())
    }

    @Test func powerBlockRetriesLater() async {
        let rig = Rig()
        let doc = UUID()
        rig.power.set(PowerState(onBattery: true, batteryPercent: 10, lowPowerMode: false))
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(5)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.provider.calls.isEmpty)
        rig.power.set(.mains)
        await rig.advance(90)
        #expect(await eventually { rig.provider.calls == [1] })
    }

    @Test func hardTimeout() async {
        let rig = Rig(hang: true)
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [1] })
        await rig.advance(19)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(rig.outcomes.value.isEmpty)
        await rig.advance(1)
        #expect(await eventually { rig.outcomes.value == [.timedOut] })
        #expect(await eventually { rig.provider.cancellations == 1 })
        #expect(rig.delivered.value.isEmpty)
        #expect(await rig.scheduler.gate(for: doc) == .alreadyAsked)   // no retry storm
    }

    @Test func newEditCancelsInFlight() async {
        let rig = Rig(hang: true)
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [1] })
        await rig.scheduler.contextChanged(context(gen: 2, doc: doc))
        #expect(await eventually { rig.provider.cancellations == 1 })
        #expect(await eventually { rig.outcomes.value == [.cancelled] })
        #expect(rig.delivered.value.isEmpty)
    }

    @Test func goingInactiveCancelsAndAllowsReask() async {
        let rig = Rig(hang: true)
        let doc = UUID()
        await rig.scheduler.contextChanged(context(gen: 1, doc: doc))
        await rig.advance(5)
        #expect(await eventually { rig.provider.calls == [1] })
        await rig.scheduler.setAppActive(false)
        #expect(await eventually { rig.provider.cancellations == 1 })
        await rig.scheduler.setAppActive(true)
        await rig.advance(100)
        #expect(await eventually { rig.provider.calls == [1, 1] })
    }

    /// Smoke test on the real clock: a hanging provider still gives nil and
    /// is cancelled exactly once. No wall-time bound (runner load varies);
    /// the timing itself is covered on FakeClock below.
    @Test func raceOnSystemClockTimesOut() async {
        let p = FakeProvider(hang: true)
        let r = await OwlScheduler.race(provider: p, context: context(), clock: SystemClock(), timeout: 0.05)
        #expect(r == nil)
        #expect(p.cancellations == 1)
    }

    /// The race's own timeout on an injected clock: a hanging provider gives
    /// nil once the clock passes the timeout (not before), and is cancelled.
    /// Measured on the clock, not the wall: a loaded CI runner took 2.2 s
    /// of real time for a 0.2 s sleep. Quarter steps keep the sums exact.
    @Test func raceTimesOutAndCancelsHangingProvider() async {
        let p = FakeProvider(hang: true)
        let clock = FakeClock()
        let done = Box(false)
        let race = Task { () -> [OwlHint]? in
            let r = await OwlScheduler.race(provider: p, context: context(), clock: clock, timeout: 0.5)
            done.mutate { $0 = true }
            return r
        }
        #expect(await eventually { clock.pendingSleepers == 1 && p.calls == [1] })
        clock.advance(0.25)
        try? await Task.sleep(nanoseconds: 30_000_000)
        #expect(!done.value && p.cancellations == 0)
        clock.advance(0.25)
        #expect(await race.value == nil)
        #expect(p.cancellations == 1)
    }
}
