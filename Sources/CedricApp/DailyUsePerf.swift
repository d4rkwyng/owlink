import AppKit
import CedricCore
import WebKit

/// The daily-use pass's speed measurements (docs/daily-use.md).
///
///   CEDRIC_CHECK=dailyuseperf    one launch's samples, on the dailyuse fixture:
///     sidebar_md_ms      a real click on a small .md row → its tab's text
///                        laid out and the window displayed (the file opens
///                        fresh each time: its tab is closed in between)
///     sidebar_log_ms     the same for the 5 MB .log
///     sidebar_switch_ms  a click on the row of a file already open → its
///                        tab selected and displayed
///     preview_toggle_ms  ⌥⌘P on a Markdown tab → the document's heading
///                        is in the page WebKit loaded, laid out, as read
///                        back from the page (dailyPreviewRendered); a
///                        heading that never comes fails the sample
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
///     (CEDRIC_DAILYUSE_HOST, CEDRIC_DAILYUSE_NOTES: a file of note lines),
///     but only from a complete collection: CEDRIC_DAILYUSE_RUNS perf
///     launches and CEDRIC_DAILYUSE_COLD cold launches, none failed,
///     skipped or under heavy load (DailyUseBudget.baselines); otherwise
///     the file is left as it is. CEDRIC_DAILYUSE_METRICS (comma
///     separated) re-measures those metrics only, keeping the others.
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

    /// Marks the document `web` shows now as the one before (the mark
    /// goes with the document): dailyPreviewRendered then waits for the
    /// next one. For a web view that is kept across a load; a preview
    /// toggled on has a new web view and needs none.
    static func dailyPreviewExpire(_ web: WKWebView?, then: @escaping @MainActor () -> Void) {
        guard let web else { then(); return }
        web.evaluateJavaScript("window.__dailyUseStale = true; 1", in: nil, in: .defaultClient) { _ in MainActor.assumeIsolated { then() } }
    }

    /// The preview's endpoint: hands over the ms since `t0` once the page
    /// WebKit has loaded in `web` (not one marked by dailyPreviewExpire)
    /// has an <h1> with
    /// `heading` in it and a laid-out box, as the page itself reports (asked again every
    /// millisecond: a probe is a round trip to the page's process, so it
    /// is answered after whatever that process was doing). Then the
    /// window is displayed. nil when the heading has not come within
    /// `timeout` s (a blank or stuck preview). Submitting the load
    /// (PreviewController's pageLoads, bodySwaps) is not the endpoint.
    /// Painting to the screen is not timed: with the screen locked WebKit
    /// has no display refresh to wait for.
    static func dailyPreviewRendered(since t0: CFAbsoluteTime, web: @escaping @MainActor () -> WKWebView?, heading: String, timeout: Double = 10,
                                     window: @escaping @MainActor () -> NSWindow? = { nil }, then: @escaping @MainActor (Double?) -> Void) {
        let needle = heading.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        // A document marked by dailyPreviewExpire is the page before: until
        // the new page commits, the web view still answers for it.
        let js = "(() => { if (window.__dailyUseStale) return 0; const h = document.querySelector('h1'); "
            + "return h && h.textContent.includes('\(needle)') && h.getBoundingClientRect().height > 0 ? 1 : 0 })()"
        var done = false
        @MainActor func end(_ ms: Double?) {
            guard !done else { return }
            done = true
            then(ms)
        }
        @MainActor func again() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.001) { MainActor.assumeIsolated { probe() } }
        }
        @MainActor func probe() {
            guard !done else { return }
            if CFAbsoluteTimeGetCurrent() - t0 > timeout { end(nil); return }
            guard let w = web() else { again(); return }
            w.evaluateJavaScript(js, in: nil, in: .defaultClient) { result in
                MainActor.assumeIsolated {
                    guard !done else { return }
                    if case .success(let v) = result, (v as? NSNumber)?.intValue == 1 {
                        window()?.displayIfNeeded()
                        end((CFAbsoluteTimeGetCurrent() - t0) * 1000)
                    } else {
                        again()
                    }
                }
            }
        }
        // A page process that never answers: the probe above would wait forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout + 0.5) { MainActor.assumeIsolated { end(nil) } }
        probe()
    }

    static func dailyUsePerfRun(_ app: AppDelegate, _ fx: DailyUseFixture, samples: Int, loadStart: DailyUseLoad) {
        let h = DailyUseHarness.main
        let md = fx.a.appendingPathComponent("notes.md")
        let anchor = fx.a.appendingPathComponent("main.swift")
        var results: [String: [Double]] = [:]
        func sample(_ metric: String, _ v: Double?) {
            guard let v else { h.check(false, "\(metric): a sample reached its endpoint within 10 s"); return }
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
                // A preview left showing would have its heading already.
                if t.previewVisible || t.previewPane != nil { h.check(false, "perf: the preview is hidden before the toggle") }
                let t0 = CFAbsoluteTimeGetCurrent()
                key("p", [.command, .option])
                dailyPreviewRendered(since: t0, web: { t.previewVisible ? t.preview?.webView : nil }, heading: "Daily Use Readme", window: { t.window }) { ms in
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
            let asked = env["CEDRIC_DAILYUSE_METRICS"].map { $0.split(separator: ",").map(String.init) } ?? metrics
            let notes = (env["CEDRIC_DAILYUSE_NOTES"].flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? "")
                .split(separator: "\n").map(String.init)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd"
            do {
                let file = try DailyUseBudget.writeBaselines(
                    from: r, metrics: asked, runs: env["CEDRIC_DAILYUSE_RUNS"].flatMap(Int.init) ?? 0, cold: env["CEDRIC_DAILYUSE_COLD"].flatMap(Int.init) ?? 0,
                    to: URL(fileURLWithPath: budgetsPath), measured: f.string(from: Date()),
                    host: env["CEDRIC_DAILYUSE_HOST"] ?? ProcessInfo.processInfo.hostName, notes: notes)
                for m in asked.sorted() {
                    guard let e = file.metrics[m] else { continue }
                    h.note(String(format: "baseline %@ = %.1f ms (median of %@), budget %.1f ms", m, e.baseline_ms, "\(e.runs_ms)", e.budget_ms))
                }
                h.check(true, "budget: wrote \(asked.count) baselines to \(budgetsPath)")
            } catch let e as DailyUseIncomplete {
                h.check(false, "budget: baselines not written, \(budgetsPath) is left as it was (the collection is not complete)", e.problems.joined(separator: "; "))
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
        if !r.failedRuns.isEmpty { h.note("perf launches that failed (their own logs have the FAIL lines): runs \(r.failedRuns)") }
        for m in metrics {
            let samples = r.samples[m] ?? []
            if samples.isEmpty && m != DailyUseBudget.coldMetric && !r.skippedRuns.isEmpty { continue }
            if let value = DailyUseBudget.median(samples.map(\.value)) { print(String(format: "metric %@=%.1f", m, value)) }
            h.note("\(m): samples \(samples.map { String(format: "%.1f%@", $0.value, $0.heavy ? " (heavy load in its run)" : "") })")
            h.record(DailyUseBudget.evaluate(metric: m, samples: samples, entry: budgets?.metrics[m]))
        }
        h.finish()
    }
}
