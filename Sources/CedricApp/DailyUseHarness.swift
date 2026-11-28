import AppKit
import CedricCore

/// The daily-use pass's harness (docs/daily-use.md): assertions, known-bug
/// markers with XCTExpectFailure(strict: true) semantics (the verdict
/// rules are CedricCore's DailyUseVerdict), named steps that print their
/// wall time and snapshot the window after each, and a main-thread hang
/// watchdog. Used by DailyUseCheck.swift (CEDRIC_CHECK=dailyuse) and
/// DailyUsePerf.swift (CEDRIC_CHECK=dailyuseperf).
///
///   CEDRIC_CHECK=dailyuseselftest     proves the strict flip: a marker
///                                     whose assertions all pass fails the
///                                     run, one that still fails is a note
///   CEDRIC_DAILYUSE_SELFTEST_HANG=1   …and then blocks the main thread
///                                     past the watchdog (it must print
///                                     "check: FAIL hang in …" and exit 1)
@MainActor
final class DailyUseHarness {
    /// The pass's harness ("check: " lines, the ones Scripts/daily-use.sh reads).
    static let main = DailyUseHarness(prefix: "check: ")

    let prefix: String
    private(set) var tally = DailyUseTally()
    private(set) var outcomes: [DailyUseOutcome] = []
    /// The open known-bug marker: its id, note and what was asserted in it.
    private var group: (id: String, note: String, assertions: [DailyUseAssertion])?

    init(prefix: String) { self.prefix = prefix }

    private func say(_ s: String) {
        print(prefix + s)
        fflush(stdout)
    }

    private func line(_ o: DailyUseOutcome) -> String {
        let l = o.line
        return l.hasPrefix("check: ") ? String(l.dropFirst("check: ".count)) : l
    }

    func record(_ o: DailyUseOutcome) {
        tally.add(o)
        outcomes.append(o)
        say(line(o))
    }

    /// An assertion: counted, or held by the open known-bug marker.
    func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        let a = DailyUseAssertion(name, passed: ok, detail: ok ? "" : detail())
        if group != nil {
            group?.assertions.append(a)
            say("note: [known-bug \(group!.id)] \(ok ? "passes" : "fails"): \(name)\(ok ? "" : " " + a.detail)")
            return
        }
        record(DailyUseVerdict.plain(a))
    }

    func note(_ s: String) { say("note: \(s)") }

    func skip(_ name: String, _ reason: String) { record(.skip(name, reason: reason)) }

    /// Opens a known-bug marker: the assertions until `endKnownBug` are
    /// EXPECTED to fail (the bug is open on main). Keep a comment at the
    /// call site naming the branch that fixes it: whoever merges the fix
    /// removes the marker, which then fails the run until they do.
    func beginKnownBug(_ id: String, note: String) {
        if let g = group { record(.fail("known-bug \(g.id)", detail: "a marker was still open when \(id) began")) }
        group = (id, note, [])
    }

    @discardableResult
    func endKnownBug() -> DailyUseOutcome? {
        guard let g = group else { record(.fail("known-bug", detail: "endKnownBug without a marker")); return nil }
        group = nil
        let o = DailyUseVerdict.knownBug(id: g.id, note: g.note, g.assertions)
        record(o)
        return o
    }

    /// A marker around synchronous assertions.
    @discardableResult
    func knownBug(id: String, note: String, _ body: () -> Void) -> DailyUseOutcome? {
        beginKnownBug(id, note: note)
        body()
        return endKnownBug()
    }

    /// Folds in what DevChecks' own helpers counted (until, snapshot, key).
    func absorbDevChecks() {
        for _ in 0..<DevChecks.passed { tally.add(.pass("")) }
        for _ in 0..<DevChecks.failed { tally.add(.fail("", detail: "")) }
        DevChecks.passed = 0
        DevChecks.failed = 0
    }

    func finish() -> Never {
        if let g = group { record(.fail("known-bug \(g.id)", detail: "the marker was never closed")) }
        absorbDevChecks()
        say(String(tally.summary.dropFirst("check: ".count)))
        exit(tally.exitCode)
    }

    // MARK: Steps

    /// A named step: does its work, then calls `next`.
    struct Step {
        var name: String
        var snapshot: Bool
        var body: (@escaping () -> Void) -> Void
    }

    static func step(_ name: String, snapshot: Bool = true, _ body: @escaping (@escaping () -> Void) -> Void) -> Step {
        Step(name: name, snapshot: snapshot, body: body)
    }

    static func sync(_ name: String, snapshot: Bool = true, _ f: @escaping () -> Void) -> Step {
        Step(name: name, snapshot: snapshot) { next in f(); next() }
    }

    /// Polls `cond` every `every` s for at most `timeout` s, then `then(met)`.
    static func poll(_ timeout: Double, every: Double = 0.02, _ cond: @escaping @MainActor () -> Bool,
                     then: @escaping @MainActor (Bool) -> Void) {
        let deadline = Date().addingTimeInterval(timeout)
        @MainActor func tick() {
            if cond() { then(true); return }
            guard Date() < deadline else { then(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + every) { MainActor.assumeIsolated { tick() } }
        }
        tick()
    }

    /// The snapshot counter: NN in NN-flow-step.png.
    private var shot = 0

    /// Runs the steps in order: prints each step's wall time, snapshots
    /// the front window after it into CEDRIC_CHECK_OUT as
    /// NN-flow-step.png, keeps the watchdog told which step runs; then
    /// `done` (finish by default).
    func run(_ steps: [Step], window: @escaping @MainActor () -> NSWindow? = { DevChecks.frontWindow },
             done: (@MainActor () -> Void)? = nil) {
        var i = 0
        @MainActor func next() {
            guard i < steps.count else {
                if let done { done() } else { finish() }
                return
            }
            let s = steps[i]
            i += 1
            HangWatchdog.shared.step = s.name
            let t0 = CFAbsoluteTimeGetCurrent()
            s.body {
                MainActor.assumeIsolated {
                    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                    self.say(String(format: "step %@ %.0f ms", s.name, ms))
                    guard s.snapshot, let w = window() else {
                        DispatchQueue.main.async { MainActor.assumeIsolated { next() } }
                        return
                    }
                    self.shot += 1
                    let file = String(format: "%02d-%@.png", self.shot, s.name)
                    let path = DevChecks.out.appendingPathComponent(file).path
                    DevHooks.write(window: w, to: path) {
                        if !FileManager.default.fileExists(atPath: path) { self.check(false, "snapshot \(file)", "not written") }
                        self.say("snapshot \(path)")
                        next()
                    }
                }
            }
        }
        next()
    }
}

/// A background timer that fails the run when the main thread stops
/// turning its run loop for `limit` seconds: prints
/// "check: FAIL hang in <step>", a sample(1) of the process (main thread
/// first) into CEDRIC_CHECK_OUT/hang-sample.txt, and exits 1.
final class HangWatchdog: @unchecked Sendable {
    static let shared = HangWatchdog()

    private let lock = NSLock()
    private var lastBeat = CFAbsoluteTimeGetCurrent()
    private var current = "launch"
    private var timer: DispatchSourceTimer?
    private(set) var limit: Double = 10

    var step: String {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue; lastBeat = CFAbsoluteTimeGetCurrent() } }
    }

    @MainActor func start(limit: Double = 10, out: URL) {
        self.limit = limit
        lock.withLock { lastBeat = CFAbsoluteTimeGetCurrent() }
        // The beat: a timer on the main run loop, in the common modes (so
        // a menu's or a drag's tracking loop counts as turning).
        let beat = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.lock.withLock { self.lastBeat = CFAbsoluteTimeGetCurrent() }
        }
        RunLoop.main.add(beat, forMode: .common)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        t.schedule(deadline: .now() + 1, repeating: 0.5)
        t.setEventHandler { [weak self] in self?.tick(out: out) }
        t.resume()
        timer = t
    }

    private func tick(out: URL) {
        let (stalled, name) = lock.withLock { (CFAbsoluteTimeGetCurrent() - lastBeat, current) }
        guard stalled > limit else { return }
        timer?.cancel()
        print(String(format: "check: FAIL hang in %@ (the main thread has not turned its run loop for %.1f s)", name, stalled))
        fflush(stdout)
        // sample(1): a couple of seconds, only on a hang; the main thread is
        // listed first. Best effort.
        let file = out.appendingPathComponent("hang-sample.txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(getpid())", "1", "-mayDie", "-file", file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        if (try? p.run()) != nil {
            let deadline = Date().addingTimeInterval(8)
            while p.isRunning && Date() < deadline { usleep(100_000) }
            if p.isRunning { p.terminate() }
        }
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            // The main thread's stack, its first lines (the whole sample is in the file).
            let lines = text.components(separatedBy: "\n")
            if let start = lines.firstIndex(where: { $0.contains("Thread_") && $0.contains("main-thread") }) ?? lines.firstIndex(where: { $0.contains("Thread_") }) {
                print("check: hang backtrace (main thread, from \(file.path)):")
                for l in lines[start..<min(lines.count, start + 40)] { print("check:   \(l)") }
            }
        } else {
            print("check: note: no sample of the hang (sample(1) did not run)")
        }
        print("check: done 0 passed, 1 failed (hang)")
        fflush(stdout)
        exit(1)
    }
}

@MainActor
extension DevChecks {
    /// The daily-use checks: true if `name` is one of them.
    static func dailyUseCheck(_ name: String, _ app: AppDelegate) -> Bool {
        switch name {
        case "dailyuse": dailyUseFlows(app)
        case "dailyuseperf": dailyUsePerf(app)
        case "dailyusebudget": dailyUseBudget(app)
        case "dailyuseselftest": dailyUseSelfTest(app)
        default: return false
        }
        return true
    }

    static func startHangWatchdog() {
        let limit = DevEnvironment.values["CEDRIC_DAILYUSE_HANG_S"].flatMap(Double.init) ?? 10
        HangWatchdog.shared.start(limit: limit, out: out)
    }

    /// The harness proves its own strict flip on a scratch harness (its
    /// lines are "selftest: …", so a runner reading "check: FAIL" does not
    /// count them), then reports on the real one.
    static func dailyUseSelfTest(_ app: AppDelegate) {
        startHangWatchdog()
        let h = DailyUseHarness.main
        let scratch = DailyUseHarness(prefix: "selftest: ")
        let fixed = scratch.knownBug(id: "selftest-fixed", note: "everything inside passes") {
            scratch.check(true, "first")
            scratch.check(true, "second")
        }
        h.check(fixed == .unexpectedPass(id: "selftest-fixed") && scratch.tally.failed == 1,
                "a known-bug marker whose assertions all pass is an UNEXPECTED-PASS failure (strict)", "\(String(describing: fixed)) \(scratch.tally)")
        let open = scratch.knownBug(id: "selftest-open", note: "still broken") {
            scratch.check(true, "passing part")
            scratch.check(false, "failing part", "as expected")
        }
        h.check(open.map { !$0.isFailure && $0.line.hasPrefix("check: KNOWN-BUG selftest-open (still open:") } == true && scratch.tally.knownBugs == 1 && scratch.tally.failed == 1,
                "a marker with a failing assertion is a KNOWN-BUG note, not a failure", "\(String(describing: open)) \(scratch.tally)")
        let empty = scratch.knownBug(id: "selftest-empty", note: "") {}
        h.check(empty?.isFailure == true, "a marker with no assertions is a failure", "\(String(describing: empty))")
        scratch.check(false, "plain failure", "x")
        h.check(scratch.tally.failed == 3 && scratch.tally.exitCode == 1, "a plain failure fails the run", "\(scratch.tally)")
        guard DevEnvironment.values["CEDRIC_DAILYUSE_SELFTEST_HANG"] == "1" else { h.finish() }
        h.note("blocking the main thread for \(HangWatchdog.shared.limit + 5) s: the watchdog must end the run")
        HangWatchdog.shared.step = "selftest-hang"
        Thread.sleep(forTimeInterval: HangWatchdog.shared.limit + 5)
        h.check(false, "the hang watchdog ended the run", "the main thread came back")
        h.finish()
    }
}
