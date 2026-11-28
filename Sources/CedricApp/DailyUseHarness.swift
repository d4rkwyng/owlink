import AppKit
import CedricCore
import WebKit

/// The daily-use pass's harness (docs/daily-use.md): assertions, known-bug
/// markers with XCTExpectFailure(strict: true) semantics (the verdict
/// rules are CedricCore's DailyUseVerdict), named steps that print their
/// wall time and snapshot the window after each, and a main-thread hang
/// watchdog. Used by DailyUseCheck.swift (CEDRIC_CHECK=dailyuse) and
/// DailyUsePerf.swift (CEDRIC_CHECK=dailyuseperf).
///
///   CEDRIC_CHECK=dailyuseselftest     proves the strict flip: a marker
///                                     whose assertions all pass fails the
///                                     run, one that still fails is a note;
///                                     and the preview timing's endpoint: a
///                                     heading that comes late is timed
///                                     late, one that never comes is no
///                                     sample (dailyPreviewRendered)
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
            let deadline = Date().addingTimeInterval(5)
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
    /// The bundle id of the copy Scripts/daily-use.sh runs: its defaults
    /// and its recent-documents list are its own.
    static let dailyUseBundleID = "net.mindtricks.cedric.dailyuse"

    /// The daily-use checks: true if `name` is one of them.
    static func dailyUseCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard ["dailyuse", "dailyuseperf", "dailyusebudget", "dailyuseselftest"].contains(name) else { return false }
        dailyUseRequireIsolation()
        switch name {
        case "dailyuse": dailyUseFlows(app)
        case "dailyuseperf": dailyUsePerf(app)
        case "dailyusebudget": dailyUseBudget(app)
        default: dailyUseSelfTest(app)
        }
        return true
    }

    /// Why this launch is not the isolated one Scripts/daily-use.sh makes
    /// (nil: it is). The flows open files (each open goes to the
    /// recent-documents list), write defaults (wrapLines, the AI engine)
    /// and list Settings › Cedric's models, so they run only as the copy
    /// with its own bundle id and with every folder and suite pointed
    /// away from the user's. Decided from the bundle id and the
    /// environment alone: nothing of the user's is looked at.
    static func dailyUseIsolationProblem(bundleID: String?, env: [String: String], home: String) -> String? {
        guard bundleID == dailyUseBundleID else {
            return "the bundle id is \(bundleID ?? "none"), not \(dailyUseBundleID): this build shares the user's defaults and recent documents"
        }
        for key in ["CEDRIC_SESSION_DIR", "CEDRIC_REPLACE_UNDO_DIR", "CEDRIC_MODELS_DIR"] {
            guard let v = env[key], !v.isEmpty else { return "\(key) is not set" }
            let path = URL(fileURLWithPath: v).standardizedFileURL.path
            if path == home + "/Library" || path.hasPrefix(home + "/Library/") { return "\(key) is inside ~/Library (\(v))" }
        }
        guard let suite = env["CEDRIC_AI_DEFAULTS"], suite.hasPrefix(dailyUseBundleID) else {
            return "CEDRIC_AI_DEFAULTS is \(env["CEDRIC_AI_DEFAULTS"] ?? "not set"), not a \(dailyUseBundleID) suite"
        }
        guard env["CEDRIC_NO_RESTORE"] == "1", env["CEDRIC_NO_SESSION_SAVE"] == "1" else { return "CEDRIC_NO_RESTORE and CEDRIC_NO_SESSION_SAVE are not both 1" }
        return nil
    }

    /// Ends the launch (exit 1, nothing opened by a check) unless it is
    /// isolated; else prints what it runs with, which the runner compares
    /// with what it set.
    static func dailyUseRequireIsolation() {
        let env = DevEnvironment.values
        if let why = dailyUseIsolationProblem(bundleID: Bundle.main.bundleIdentifier, env: env, home: NSHomeDirectory()) {
            print("check: FAIL isolation: \(why). Run Scripts/daily-use.sh, which makes the isolated copy; nothing was run.")
            print("check: done 0 passed, 1 failed, 0 known bugs, 0 skipped")
            fflush(stdout)
            exit(1)
        }
        print("check: note: isolation: bundle=\(Bundle.main.bundleIdentifier ?? "") app=\(Bundle.main.bundlePath) session=\(env["CEDRIC_SESSION_DIR"] ?? "") replace-undo=\(env["CEDRIC_REPLACE_UNDO_DIR"] ?? "") models=\(env["CEDRIC_MODELS_DIR"] ?? "") ai-defaults=\(env["CEDRIC_AI_DEFAULTS"] ?? "")")
        fflush(stdout)
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
        // The isolation rule, on made-up launches (nothing is looked at).
        let good = ["CEDRIC_SESSION_DIR": "/tmp/x/session", "CEDRIC_REPLACE_UNDO_DIR": "/tmp/x/undo", "CEDRIC_MODELS_DIR": "/tmp/x/models",
                    "CEDRIC_AI_DEFAULTS": dailyUseBundleID + ".ai", "CEDRIC_NO_RESTORE": "1", "CEDRIC_NO_SESSION_SAVE": "1"]
        func problem(_ id: String?, _ change: (inout [String: String]) -> Void = { _ in }) -> String? {
            var e = good
            change(&e)
            return dailyUseIsolationProblem(bundleID: id, env: e, home: "/Users/someone")
        }
        h.check(problem(dailyUseBundleID) == nil, "isolation: the copy with its scratch folders and suite may run")
        h.check(problem("net.mindtricks.cedric") != nil && problem(nil) != nil, "isolation: the build with the user's bundle id may not run")
        h.check(problem(dailyUseBundleID) { $0["CEDRIC_MODELS_DIR"] = nil } != nil
                && problem(dailyUseBundleID) { $0["CEDRIC_SESSION_DIR"] = "/Users/someone/Library/Application Support/Cedric/Session" } != nil
                && problem(dailyUseBundleID) { $0["CEDRIC_REPLACE_UNDO_DIR"] = "/Users/someone/Library/../Library/x" } != nil
                && problem(dailyUseBundleID) { $0["CEDRIC_AI_DEFAULTS"] = "net.mindtricks.cedric" } != nil
                && problem(dailyUseBundleID) { $0["CEDRIC_NO_SESSION_SAVE"] = nil } != nil,
                "isolation: a missing folder, one inside ~/Library, the user's AI suite or a saved session may not run")
        guard DevEnvironment.values["CEDRIC_DAILYUSE_SELFTEST_HANG"] == "1" else { dailyUsePreviewEndpointSelfTest(); return }
        h.note("blocking the main thread for \(HangWatchdog.shared.limit + 20) s (a hang stays: sample(1) needs a few seconds): the watchdog must end the run")
        HangWatchdog.shared.step = "selftest-hang"
        Thread.sleep(forTimeInterval: HangWatchdog.shared.limit + 20)
        h.check(false, "the hang watchdog ended the run", "the main thread came back")
        h.finish()
    }

    /// Proves the preview timing's endpoint (dailyPreviewRendered, what
    /// preview_toggle_ms stops at) on a web view of its own: a heading
    /// there at once is timed; one that comes 400 ms after the load was
    /// submitted is timed at least 400 ms; one that never comes is no
    /// sample. Then finishes the self-test.
    static var selfTestWeb: WKWebView?

    static func dailyUsePreviewEndpointSelfTest() {
        let h = DailyUseHarness.main
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 320))
        selfTestWeb = web
        let heading = "Daily Use Readme"
        func page(_ body: String) -> String { "<!doctype html><html><body>\(body)</body></html>" }
        HangWatchdog.shared.step = "selftest-preview-at-once"
        var t0 = CFAbsoluteTimeGetCurrent()
        web.loadHTMLString(page("<h1>\(heading)</h1>"), baseURL: nil)
        dailyPreviewRendered(since: t0, web: { web }, heading: heading, timeout: 5) { atOnce in
            h.check(atOnce != nil, "preview endpoint: a heading in the loaded page is a sample", "none within 5 s")
            HangWatchdog.shared.step = "selftest-preview-late"
            // The page before has the heading: it is marked, so it does not count.
            dailyPreviewExpire(web) {
            t0 = CFAbsoluteTimeGetCurrent()
            // The load is submitted now; the heading arrives 400 ms later.
            web.loadHTMLString(page("<p>loading</p>"), baseURL: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                web.evaluateJavaScript("document.body.innerHTML = '<h1>\(heading)</h1>'; 1", in: nil, in: .defaultClient) { _ in }
            }
            dailyPreviewRendered(since: t0, web: { web }, heading: heading, timeout: 5) { late in
                h.note(String(format: "preview endpoint: heading at once %.1f ms, heading 400 ms after the load was submitted %.1f ms", atOnce ?? -1, late ?? -1))
                // (The first sample has the web process's launch in it, so the two are not compared.)
                h.check((late ?? 0) >= 400 && (late ?? 0) < 3000,
                        "preview endpoint: a delay between submitting the load and the heading appearing is in the sample (at least the 400 ms)",
                        String(format: "%.1f ms", late ?? -1))
                HangWatchdog.shared.step = "selftest-preview-never"
                dailyPreviewExpire(web) {
                t0 = CFAbsoluteTimeGetCurrent()
                web.loadHTMLString(page("<h1>Something else</h1><p>blank</p>"), baseURL: nil)
                dailyPreviewRendered(since: t0, web: { web }, heading: heading, timeout: 1) { never in
                    h.check(never == nil, "preview endpoint: a heading that never appears is no sample (the perf run fails it)",
                            String(format: "%.1f ms", never ?? -1))
                    selfTestWeb = nil
                    h.finish()
                }
                }
            }
            }
        }
    }
}
