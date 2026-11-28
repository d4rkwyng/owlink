import Foundation
import Testing
@testable import CedricCore

/// The daily-use pass's verdict rules (known bugs with strict
/// expected-failure semantics) and speed-budget evaluation.
@Suite struct DailyUseVerdictTests {
    let ok = DailyUseAssertion("root follows", passed: true)
    let bad = DailyUseAssertion("file selected", passed: false, detail: "row -1")

    @Test func plainPassAndFail() {
        #expect(DailyUseVerdict.plain(ok) == .pass("root follows"))
        #expect(DailyUseVerdict.plain(ok).isFailure == false)
        let f = DailyUseVerdict.plain(bad)
        #expect(f == .fail("file selected", detail: "row -1"))
        #expect(f.isFailure)
        #expect(f.line == "check: FAIL file selected row -1")
    }

    @Test func expectedFailureIsANote() {
        let o = DailyUseVerdict.knownBug(id: "sidebar-follow", note: "root stays on A", [bad])
        #expect(o == .knownBug(id: "sidebar-follow", detail: "root stays on A; file selected: row -1"))
        #expect(!o.isFailure)
        #expect(o.line == "check: KNOWN-BUG sidebar-follow (still open: root stays on A; file selected: row -1)")
    }

    @Test func unexpectedPassFailsTheRun() {
        let o = DailyUseVerdict.knownBug(id: "settings-cedric-tall", note: "", [ok, ok])
        #expect(o == .unexpectedPass(id: "settings-cedric-tall"))
        #expect(o.isFailure)
        #expect(o.line == "check: FAIL UNEXPECTED-PASS settings-cedric-tall: the bug is fixed, remove the knownBug marker")
    }

    @Test func mixedAssertionsInOneMarkerStillOpen() {
        // One of two still fails: still open, naming only the failing one.
        let o = DailyUseVerdict.knownBug(id: "x", note: "", [ok, bad])
        #expect(o == .knownBug(id: "x", detail: "file selected: row -1"))
        #expect(!o.isFailure)
    }

    @Test func anEmptyMarkerIsAFailure() {
        let o = DailyUseVerdict.knownBug(id: "x", note: "n", [])
        #expect(o.isFailure)
        if case .fail = o {} else { Issue.record("not a plain failure: \(o)") }
    }

    @Test func tallyCountsAndExitCode() {
        var t = DailyUseTally()
        t.add(.pass("a"))
        t.add(.knownBug(id: "k", detail: "d"))
        t.add(.skip("m", reason: "load"))
        #expect(t.exitCode == 0)
        #expect(t.summary == "check: done 1 passed, 0 failed, 1 known bugs, 1 skipped")
        t.add(.unexpectedPass(id: "k"))
        #expect(t.failed == 1 && t.exitCode == 1)
        #expect(DailyUseTally().exitCode == 1, "nothing ran is not a pass")
        var skips = DailyUseTally()
        skips.add(.skip("perf", reason: "heavy"))
        #expect(skips.exitCode == 1, "only skips is not a pass")
    }
}

@Suite struct DailyUseBudgetTests {
    @Test func median() {
        #expect(DailyUseBudget.median([]) == nil)
        #expect(DailyUseBudget.median([5]) == 5)
        #expect(DailyUseBudget.median([9, 1, 5]) == 5)
        #expect(DailyUseBudget.median([4, 1, 3, 2]) == 2.5)
    }

    @Test func warmUpSampleIsDropped() {
        #expect(DailyUseBudget.measured([900, 10, 12, 11]) == [10, 12, 11])
        #expect(DailyUseBudget.measured([]) == [])
    }

    @Test func budgetIsBaselinePlus30PercentBetweenFloorAndCap() {
        #expect(DailyUseBudget.budget(baseline: 100, floor: 40, cap: 250) == 130)
        #expect(DailyUseBudget.budget(baseline: 10, floor: 40, cap: 250) == 40, "the floor")
        #expect(DailyUseBudget.budget(baseline: 300, floor: 40, cap: 250) == 250, "the cap")
    }

    @Test func entryFromRunMedians() throws {
        let e = try #require(DailyUseBudget.entry(metric: "sidebar_md_ms", runMedians: [50, 40, 60, 45, 55]))
        #expect(e.baseline_ms == 50)
        #expect(e.budget_ms == 65)
        #expect(e.runs_ms == [50, 40, 60, 45, 55])
        #expect(DailyUseBudget.entry(metric: "sidebar_md_ms", runMedians: []) == nil)
    }

    @Test func loadClassification() {
        #expect(DailyUseLoad(oneMinute: 7, cores: 14).isHeavy() == false)
        #expect(DailyUseLoad(oneMinute: 30, cores: 14).isHeavy())
        #expect(DailyUseLoad(oneMinute: 3, cores: 0).cores == 1)
    }

    @Test func evaluation() {
        let e = DailyUseBudgetEntry(baseline_ms: 50, budget_ms: 65, cap_ms: 250, floor_ms: 40, runs_ms: [50])
        func calm(_ xs: Double...) -> [DailyUseSample] { xs.map { DailyUseSample($0) } }
        func heavy(_ xs: Double...) -> [DailyUseSample] { xs.map { DailyUseSample($0, heavy: true) } }
        #expect(!DailyUseBudget.evaluate(metric: "m", samples: calm(60), entry: e).isFailure)
        if case .pass = DailyUseBudget.evaluate(metric: "m", samples: heavy(60), entry: e) {} else { Issue.record("under budget passes under load") }
        let over = DailyUseBudget.evaluate(metric: "m", samples: calm(70), entry: e)
        #expect(over.isFailure, "over budget, calm: FAIL")
        let loaded = DailyUseBudget.evaluate(metric: "m", samples: heavy(70), entry: e)
        #expect(!loaded.isFailure)
        #expect(loaded.line.hasPrefix("check: SKIP m: over budget under load"))
        if case .skip = DailyUseBudget.evaluate(metric: "m", samples: [], entry: e) {} else { Issue.record("no samples: skip") }
        if case .skip = DailyUseBudget.evaluate(metric: "m", samples: calm(5), entry: nil) {} else { Issue.record("no budget: skip") }
        // A budget above the cap (hand-edited file): the cap wins.
        let loose = DailyUseBudgetEntry(baseline_ms: 50, budget_ms: 900, cap_ms: 250, floor_ms: 40, runs_ms: [50])
        #expect(DailyUseBudget.evaluate(metric: "m", samples: calm(300), entry: loose).isFailure)
    }

    /// The attribution rule: the load excuses a metric only through the
    /// samples that metric's verdict is made of.
    @Test func heavyLoadIsTiedToTheSamplesBehindTheVerdict() {
        let e = DailyUseBudgetEntry(baseline_ms: 50, budget_ms: 65, cap_ms: 250, floor_ms: 40, runs_ms: [50])
        // The slowdown is in the heavy runs: the calm ones alone are within budget.
        let pushed = [DailyUseSample(60), DailyUseSample(90, heavy: true), DailyUseSample(95, heavy: true)]
        let skip = DailyUseBudget.evaluate(metric: "m", samples: pushed, entry: e)
        #expect(skip.line.hasPrefix("check: SKIP m: over budget under load: 2 of its 3 samples"), "\(skip.line)")
        // Calm runs over budget on their own: one heavy run excuses nothing.
        let slow = [DailyUseSample(80), DailyUseSample(82), DailyUseSample(90, heavy: true)]
        let fail = DailyUseBudget.evaluate(metric: "m", samples: slow, entry: e)
        #expect(fail.isFailure, "\(fail.line)")
        #expect(fail.line.contains("its 2 calm samples alone: 81.0 ms"), "\(fail.line)")
    }

    /// A heavy cold launch cannot excuse a sidebar median measured on calm
    /// perf launches (and the other way round), from the runner's lines.
    @Test func aHeavyColdLaunchDoesNotExcuseACalmPerfMetric() {
        let text = """
        cold=1 value=900.0 load_start=40.0 load_end=41.0 cores=14
        cold=2 value=910.0 load_start=3.0 load_end=41.0 cores=14
        run=1 metric=sidebar_md_ms value=70.0
        run=1 load_start=3.0 load_end=3.1 cores=14
        run=2 metric=sidebar_md_ms value=72.0
        run=2 load_start=3.0 load_end=3.2 cores=14
        """
        let r = DailyUseResults.parse(text)
        let e = DailyUseBudgetEntry(baseline_ms: 40, budget_ms: 52, cap_ms: 250, floor_ms: 40, runs_ms: [40])
        #expect(r.samples["sidebar_md_ms"] == [DailyUseSample(70), DailyUseSample(72)])
        #expect(DailyUseBudget.evaluate(metric: "sidebar_md_ms", samples: r.samples["sidebar_md_ms"] ?? [], entry: e).isFailure)
        let cold = DailyUseBudgetEntry(baseline_ms: 160, budget_ms: 300, cap_ms: 1500, floor_ms: 300, runs_ms: [160])
        #expect(r.samples["cold_launch_ms"]?.allSatisfy(\.heavy) == true)
        if case .skip = DailyUseBudget.evaluate(metric: "cold_launch_ms", samples: r.samples["cold_launch_ms"] ?? [], entry: cold) {} else {
            Issue.record("the heavy cold launches themselves are a SKIP")
        }
        // A heavy perf launch marks its own metrics only.
        let mixed = DailyUseResults.parse("""
        run=1 metric=sidebar_md_ms value=45.0
        run=1 load_start=3.0 load_end=3.0 cores=14
        run=2 metric=sidebar_md_ms value=90.0
        run=2 load_start=3.0 load_end=30.0 cores=14
        run=3 metric=sidebar_md_ms value=95.0
        run=3 load_start=3.0 load_end=30.0 cores=14
        """)
        #expect(mixed.samples["sidebar_md_ms"]?.map(\.heavy) == [false, true, true])
        if case .skip = DailyUseBudget.evaluate(metric: "sidebar_md_ms", samples: mixed.samples["sidebar_md_ms"] ?? [], entry: e) {} else {
            Issue.record("a slowdown in the heavy runs is a SKIP")
        }
    }

    @Test func budgetFileRoundTrips() throws {
        let f = DailyUseBudgetFile(measured: "2026-11-27", host: "geonosis", notes: ["n"],
                                   metrics: ["a": DailyUseBudgetEntry(baseline_ms: 1, budget_ms: 2, cap_ms: 3, floor_ms: 1, runs_ms: [1])])
        #expect(try DailyUseBudgetFile.decode(f.encoded()) == f)
    }

    @Test func resultsParse() {
        let text = """
        run=1 metric=sidebar_md_ms value=12.5
        run=1 load_start=3.1 load_end=4.2 cores=14
        run=2 metric=sidebar_md_ms value=14.5
        run=2 load_start=3.1 load_end=20.0 cores=14
        run=3 skipped=heavy
        run=4 failed=1
        cold=1 value=410.0 load_start=3.0 load_end=3.0 cores=14
        cold=2 value=420.0 load_start=3.0 load_end=3.0 cores=14
        cold=0 load_start=3.0 load_end=3.0 cores=14
        noise line
        """
        let r = DailyUseResults.parse(text)
        #expect(r.runMedians["sidebar_md_ms"] == [12.5, 14.5])
        #expect(r.samples["sidebar_md_ms"]?.map(\.heavy) == [false, true])
        #expect(r.runMedians["cold_launch_ms"] == [410, 420])
        #expect(r.skippedRuns == ["heavy"])
        #expect(r.failedRuns == ["4"])
    }
}

/// `--write-budgets`: only a complete collection replaces the budgets file.
@Suite struct DailyUseBaselineWriterTests {
    static let perf = ["preview_toggle_ms", "sidebar_log_ms", "sidebar_md_ms", "sidebar_switch_ms"]
    static let all = perf + ["cold_launch_ms"]

    /// `runs` calm perf launches and `cold` calm cold launches.
    static func lines(runs: Int, cold: Int, metrics: [String] = perf, endLoad: Double = 3) -> String {
        var l: [String] = []
        for i in 1...max(cold, 1) where cold > 0 { l.append("cold=\(i) value=\(160 + i).0 load_start=3.0 load_end=3.0 cores=14") }
        for i in 1...max(runs, 1) where runs > 0 {
            for m in metrics { l.append("run=\(i) metric=\(m) value=\(40 + i).0") }
            l.append("run=\(i) load_start=3.0 load_end=\(endLoad) cores=14")
        }
        return l.joined(separator: "\n")
    }

    static func oldFile() throws -> (URL, Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dailyuse-budgets-\(UUID().uuidString).json")
        let old = DailyUseBudgetFile(measured: "2026-01-01", host: "old", notes: ["old note"], metrics: Dictionary(uniqueKeysWithValues: all.map {
            ($0, DailyUseBudgetEntry(baseline_ms: 1, budget_ms: 2, cap_ms: 3, floor_ms: 1, runs_ms: [1]))
        }))
        let data = try old.encoded()
        try data.write(to: url)
        return (url, data)
    }

    func write(_ text: String, metrics: [String] = all, to url: URL) throws -> DailyUseBudgetFile {
        try DailyUseBudget.writeBaselines(from: DailyUseResults.parse(text), metrics: metrics, runs: 3, cold: 2, to: url,
                                          measured: "2026-11-28", host: "geonosis", notes: ["n"])
    }

    @Test func aCompleteCollectionReplacesTheFile() throws {
        let (url, old) = try Self.oldFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let f = try write(Self.lines(runs: 3, cold: 2), to: url)
        let now = try Data(contentsOf: url)
        #expect(now != old)
        #expect(try DailyUseBudgetFile.decode(now) == f)
        #expect(f.host == "geonosis" && f.notes == ["n"])
        #expect(f.metrics["sidebar_md_ms"]?.runs_ms == [41, 42, 43])
        #expect(f.metrics["sidebar_md_ms"]?.baseline_ms == 42)
        #expect(f.metrics["sidebar_md_ms"]?.budget_ms == 54.6)
        #expect(f.metrics["cold_launch_ms"]?.runs_ms == [161, 162])
        #expect(f.metrics["cold_launch_ms"]?.budget_ms == 300, "the floor")
    }

    @Test func allHeavyPartialAndFailedCollectionsKeepTheOldFile() throws {
        let (url, old) = try Self.oldFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let cases: [(String, String, String)] = [
            ("all heavy (every perf launch skipped)",
             Self.lines(runs: 0, cold: 2) + "\nrun=1 skipped=heavy-load-30.0\nrun=2 skipped=heavy-load-30.0\nrun=3 skipped=heavy-load-30.0", "perf launches skipped"),
            ("nothing measured", "", "has 0 of 3 samples"),
            ("partial: a launch short", Self.lines(runs: 2, cold: 2), "sidebar_md_ms has 2 of 3 samples"),
            ("partial: a metric missing", Self.lines(runs: 3, cold: 2, metrics: Array(Self.perf.dropFirst())), "preview_toggle_ms has 0 of 3 samples"),
            ("partial: cold launches short", Self.lines(runs: 3, cold: 1), "cold_launch_ms has 1 of 2 samples"),
            ("a failed perf launch", Self.lines(runs: 3, cold: 2) + "\nrun=2 failed=1", "perf launches failed: runs 2"),
            ("measured under heavy load", Self.lines(runs: 3, cold: 2, endLoad: 30), "samples from runs under heavy load"),
        ]
        for (name, text, why) in cases {
            do {
                _ = try write(text, to: url)
                Issue.record("\(name): wrote a budgets file")
            } catch let e as DailyUseIncomplete {
                #expect(e.problems.contains { $0.contains(why) }, "\(name): \(e.problems)")
            }
            #expect(try Data(contentsOf: url) == old, "\(name): the old file is kept byte for byte")
        }
    }

    @Test func oneMetricRemeasuredKeepsTheOthers() throws {
        let (url, _) = try Self.oldFile()
        defer { try? FileManager.default.removeItem(at: url) }
        // No cold launches and the other perf metrics are not asked for.
        let f = try write(Self.lines(runs: 3, cold: 0), metrics: ["preview_toggle_ms"], to: url)
        #expect(f.metrics["preview_toggle_ms"]?.runs_ms == [41, 42, 43])
        #expect(f.metrics["sidebar_md_ms"]?.baseline_ms == 1, "kept")
        #expect(f.metrics["cold_launch_ms"]?.baseline_ms == 1, "kept")
        #expect(f.notes == ["old note", "2026-11-28 preview_toggle_ms: n"])
        // With no old file there is nothing to keep the others from.
        let fresh = FileManager.default.temporaryDirectory.appendingPathComponent("dailyuse-budgets-\(UUID().uuidString).json")
        #expect(throws: DailyUseIncomplete.self) { try write(Self.lines(runs: 3, cold: 0), metrics: ["preview_toggle_ms"], to: fresh) }
        #expect(!FileManager.default.fileExists(atPath: fresh.path))
        #expect(throws: DailyUseIncomplete.self) { try write(Self.lines(runs: 3, cold: 2), metrics: ["nope_ms"], to: url) }
    }
}
