import AppKit
import CedricCore

/// The daily-use pass's speed measurements (docs/daily-use.md).
///
///   CEDRIC_CHECK=dailyuseperf    one launch's samples, on the dailyuse fixture:
///     sidebar_md_ms      a real click on a small .md row → its tab's text
///                        laid out and the window displayed (the file opens
///                        fresh each time: its tab is closed in between)
///     sidebar_log_ms     the same for the 5 MB .log
///     sidebar_switch_ms  a click on the row of a file already open → its
///                        tab selected and displayed
///     preview_toggle_ms  ⌥⌘P on a Markdown tab → the preview rendered
///                        and displayed
///   Each is sampled CEDRIC_DAILYUSE_SAMPLES times (default 8, at least
///   8: the first is a warm-up, printed, not counted); prints
///   "perf: metric=NAME value=MEDIAN" and the load at start and end.
///   Under heavy load at the start it waits up to 3 minutes for calm, else
///   prints "check: SKIP perf: machine under heavy load …" and exits 0.
///
///   CEDRIC_CHECK=dailyusebudget  evaluates CEDRIC_DAILYUSE_RESULTS (what
///     Scripts/daily-use.sh collected: DailyUseResults' format) against
///     CEDRIC_DAILYUSE_BUDGETS (Scripts/daily-use-budgets.json); with
///     CEDRIC_DAILYUSE_WRITE=1 writes the measured baselines there instead
///     (CEDRIC_DAILYUSE_HOST, CEDRIC_DAILYUSE_NOTES: a file of note lines).
@MainActor
extension DevChecks {
    static func dailyUsePerf(_ app: AppDelegate) {
        let h = DailyUseHarness.main
        startHangWatchdog()
        let env = DevEnvironment.values
        let samples = max(8, env["CEDRIC_DAILYUSE_SAMPLES"].flatMap(Int.init) ?? 8)
        let start = dailyLoad()
        func begin() {
            let fx = dailyUseFixture()
            dailyUsePerfRun(app, fx, samples: samples, loadStart: dailyLoad())
        }
        guard start.isHeavy() else { begin(); return }
        h.note("heavy load at the start (\(start.text), \(String(format: "%.2f", start.perCore)) per core): waiting up to 3 minutes")
        let deadline = Date().addingTimeInterval(180)
        @MainActor func wait() {
            let l = dailyLoad()
            if !l.isHeavy() { h.note("calm now (\(l.text))"); begin(); return }
            guard Date() < deadline else {
                print("check: SKIP perf: machine under heavy load (load \(String(format: "%.2f", l.oneMinute)), cores \(l.cores))")
                print("perf: skipped=heavy-load-\(String(format: "%.1f", l.oneMinute))")
                print("check: done 0 passed, 0 failed, 0 known bugs, 1 skipped")
                fflush(stdout)
                exit(0)
            }
            HangWatchdog.shared.step = "perf-wait-calm"
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { MainActor.assumeIsolated { wait() } }
        }
        wait()
    }

    /// Turns the run loop until `cond` (each turn a main-queue hop, so
    /// whatever the click queued runs), then displays `window` and hands
    /// over the ms since `t0`; nil after 10 s.
    static func dailyMeasure(since t0: CFAbsoluteTime, window: @escaping @MainActor () -> NSWindow?, _ cond: @escaping @MainActor () -> Bool,
                             then: @escaping @MainActor (Double?) -> Void) {
        @MainActor func turn() {
            if cond() {
                window()?.displayIfNeeded()
                then((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                return
            }
            if CFAbsoluteTimeGetCurrent() - t0 > 10 { then(nil); return }
            DispatchQueue.main.async { MainActor.assumeIsolated { turn() } }
        }
        turn()
    }

    static func dailyUsePerfRun(_ app: AppDelegate, _ fx: DailyUseFixture, samples: Int, loadStart: DailyUseLoad) {
        let h = DailyUseHarness.main
        let md = fx.a.appendingPathComponent("notes.md")
        let anchor = fx.a.appendingPathComponent("main.swift")
        var results: [String: [Double]] = [:]
        func sample(_ metric: String, _ v: Double?) {
            guard let v else { h.check(false, "\(metric): a sample finished within 10 s"); return }
            results[metric, default: []].append(v)
            print(String(format: "perf: sample %@ %d %.2f%@", metric, results[metric]!.count, v, results[metric]!.count == 1 ? " (warm-up)" : ""))
        }
        let size: (URL) -> Int = { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0 }
        var steps: [DailyUseHarness.Step] = []
        steps.append(DailyUseHarness.sync("perf-open-folder", snapshot: false) { app.application(NSApp, open: [fx.a]) })
        steps.append(DailyUseHarness.step("perf-listed", snapshot: false) { next in
            DailyUseHarness.poll(8, { FolderSidebar.shared?.root.isLoaded == true }) { ok in
                h.check(ok, "perf: folder A is listed")
                // A tab that stays open (closing the last tab would quit).
                dailyClickRow(anchor)
                DailyUseHarness.poll(3, { dailyTab(app, anchor) != nil }) { _ in
                    if let t = dailyTab(app, anchor) { sized(t) }
                    next()
                }
            }
        })
        // Opening fresh: md, log, md, log… each tab closed after.
        for i in 0..<(samples * 2) {
            let file = i % 2 == 0 ? md : fx.log
            let metric = i % 2 == 0 ? "sidebar_md_ms" : "sidebar_log_ms"
            steps.append(DailyUseHarness.step("perf-open-\(i)", snapshot: false) { next in
                let bytes = size(file)
                let t0 = CFAbsoluteTimeGetCurrent()
                dailyClickRow(file)
                dailyMeasure(since: t0, window: { dailyWindow(app, file) }, {
                    guard let t = dailyTab(app, file) else { return false }
                    return dailyLoaded(t, bytes: bytes) && app.currentTab === t
                }) { ms in
                    sample(metric, ms)
                    dailyWindow(app, file)?.close()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
                }
            })
        }
        // Switching between two open files.
        steps.append(DailyUseHarness.step("perf-switch-open", snapshot: false) { next in
            dailyClickRow(md)
            dailyClickRow(fx.log)
            DailyUseHarness.poll(5, { dailyTab(app, md) != nil && dailyTab(app, fx.log) != nil }) { ok in
                h.check(ok, "perf: both files open for switching")
                [md, fx.log].compactMap { dailyTab(app, $0) }.forEach { sized($0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
            }
        })
        for i in 0..<(samples * 2) {
            let file = i % 2 == 0 ? md : fx.log
            steps.append(DailyUseHarness.step("perf-switch-\(i)", snapshot: false) { next in
                let t0 = CFAbsoluteTimeGetCurrent()
                dailyClickRow(file)
                dailyMeasure(since: t0, window: { dailyWindow(app, file) }, { app.currentTab.map { $0 === dailyTab(app, file) } == true }) { ms in
                    sample("sidebar_switch_ms", ms)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { next() }
                }
            })
        }
        // Preview toggles on readme.md.
        steps.append(DailyUseHarness.step("perf-preview-open", snapshot: false) { next in
            dailyClickRow(fx.readme)
            DailyUseHarness.poll(5, { dailyTab(app, fx.readme) != nil }) { _ in
                if let t = dailyTab(app, fx.readme) { sized(t); focus(t) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
            }
        })
        for i in 0..<samples {
            steps.append(DailyUseHarness.step("perf-preview-\(i)", snapshot: false) { next in
                guard let t = dailyTab(app, fx.readme) else { h.check(false, "perf: readme.md open"); next(); return }
                focus(t)
                let t0 = CFAbsoluteTimeGetCurrent()
                key("p", [.command, .option])
                dailyMeasure(since: t0, window: { t.window }, { t.previewVisible && (t.preview?.pageLoads ?? 0) + (t.preview?.bodySwaps ?? 0) > 0 }) { ms in
                    sample("preview_toggle_ms", ms)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        key("p", [.command, .option])
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { next() }
                    }
                }
            })
        }
        steps.append(DailyUseHarness.sync("perf-report", snapshot: false) {
            let end = dailyLoad()
            for m in ["sidebar_md_ms", "sidebar_log_ms", "sidebar_switch_ms", "preview_toggle_ms"] {
                let all = results[m] ?? []
                let counted = DailyUseBudget.measured(all)
                h.check(counted.count >= 7, "perf: \(m) has at least 7 samples after the warm-up", "\(counted.count)")
                guard let med = DailyUseBudget.median(counted) else { continue }
                DevHooks.metric(m, med)
                print(String(format: "perf: metric=%@ value=%.2f", m, med))
            }
            print(String(format: "perf: load_start=%.2f load_end=%.2f cores=%d", loadStart.oneMinute, end.oneMinute, end.cores))
            h.note("load at start \(loadStart.text), at end \(end.text)\(end.isHeavy() ? " (heavy)" : "")")
            fflush(stdout)
            if DevEnvironment.values["CEDRIC_CHECK_OUT"] != nil { try? FileManager.default.removeItem(at: dir) }
        })
        h.run(steps)
    }

    /// Evaluates (or writes) the budgets from what the runner collected.
    static func dailyUseBudget(_ app: AppDelegate) {
        let h = DailyUseHarness.main
        let env = DevEnvironment.values
        guard let resultsPath = env["CEDRIC_DAILYUSE_RESULTS"], let budgetsPath = env["CEDRIC_DAILYUSE_BUDGETS"],
              let text = try? String(contentsOfFile: resultsPath, encoding: .utf8) else {
            h.check(false, "budget: CEDRIC_DAILYUSE_RESULTS and CEDRIC_DAILYUSE_BUDGETS are set and readable"); h.finish()
        }
        let r = DailyUseResults.parse(text)
        let metrics = DailyUseBudget.limits.keys.sorted()
        if env["CEDRIC_DAILYUSE_WRITE"] == "1" {
            var entries: [String: DailyUseBudgetEntry] = [:]
            for m in metrics {
                guard let e = DailyUseBudget.entry(metric: m, runMedians: r.runMedians[m] ?? []) else { h.skip(m, "no samples to write a baseline from"); continue }
                entries[m] = e
                h.note(String(format: "baseline %@ = %.1f ms (median of %@), budget %.1f ms", m, e.baseline_ms, "\(e.runs_ms)", e.budget_ms))
            }
            let notes = (env["CEDRIC_DAILYUSE_NOTES"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
                .split(separator: "\n").map(String.init)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            let file = DailyUseBudgetFile(measured: f.string(from: Date()), host: env["CEDRIC_DAILYUSE_HOST"] ?? ProcessInfo.processInfo.hostName,
                                          notes: notes, metrics: entries)
            do {
                try file.encoded().write(to: URL(fileURLWithPath: budgetsPath), options: .atomic)
                h.check(true, "budget: wrote \(entries.count) baselines to \(budgetsPath)")
            } catch {
                h.check(false, "budget: write \(budgetsPath)", "\(error)")
            }
            h.finish()
        }
        let budgets: DailyUseBudgetFile?
        do {
            budgets = try DailyUseBudgetFile.decode(Data(contentsOf: URL(fileURLWithPath: budgetsPath)))
        } catch {
            budgets = nil
            h.note("no budgets file at \(budgetsPath) (\(error.localizedDescription)): every metric is a SKIP")
        }
        let perfMetrics = metrics.filter { $0 != "cold_launch_ms" }
        if !r.skippedRuns.isEmpty { h.note("perf launches skipped: \(r.skippedRuns)") }
        if perfMetrics.allSatisfy({ (r.runMedians[$0] ?? []).isEmpty }) && !r.skippedRuns.isEmpty {
            h.skip("perf", "machine under heavy load in every perf launch (\(r.skippedRuns.joined(separator: ", ")))")
        }
        h.note("heavy load at the end of a perf launch: \(r.heavyAtEnd) (\(r.endLoads.map(\.text)))")
        for m in metrics {
            let runs = r.runMedians[m] ?? []
            if runs.isEmpty && m != "cold_launch_ms" && !r.skippedRuns.isEmpty { continue }
            let value = DailyUseBudget.median(runs)
            if let value { print(String(format: "metric %@=%.1f", m, value)) }
            h.note("\(m): per-run values \(runs.map { String(format: "%.1f", $0) })")
            h.record(DailyUseBudget.evaluate(metric: m, value: value, entry: budgets?.metrics[m], heavyAtEnd: r.heavyAtEnd))
        }
        h.finish()
    }
}
