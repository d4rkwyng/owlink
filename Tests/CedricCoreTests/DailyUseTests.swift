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
        #expect(!DailyUseBudget.evaluate(metric: "m", value: 60, entry: e, heavyAtEnd: false).isFailure)
        if case .pass = DailyUseBudget.evaluate(metric: "m", value: 60, entry: e, heavyAtEnd: true) {} else { Issue.record("under budget passes under load") }
        let over = DailyUseBudget.evaluate(metric: "m", value: 70, entry: e, heavyAtEnd: false)
        #expect(over.isFailure, "over budget, calm: FAIL")
        let loaded = DailyUseBudget.evaluate(metric: "m", value: 70, entry: e, heavyAtEnd: true)
        #expect(!loaded.isFailure)
        #expect(loaded.line.hasPrefix("check: SKIP m: over budget under load"))
        if case .skip = DailyUseBudget.evaluate(metric: "m", value: nil, entry: e, heavyAtEnd: false) {} else { Issue.record("no samples: skip") }
        if case .skip = DailyUseBudget.evaluate(metric: "m", value: 5, entry: nil, heavyAtEnd: false) {} else { Issue.record("no budget: skip") }
        // A budget above the cap (hand-edited file): the cap wins.
        let loose = DailyUseBudgetEntry(baseline_ms: 50, budget_ms: 900, cap_ms: 250, floor_ms: 40, runs_ms: [50])
        #expect(DailyUseBudget.evaluate(metric: "m", value: 300, entry: loose, heavyAtEnd: false).isFailure)
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
        cold value=410.0
        cold value=420.0
        noise line
        """
        let r = DailyUseResults.parse(text)
        #expect(r.runMedians["sidebar_md_ms"] == [12.5, 14.5])
        #expect(r.runMedians["cold_launch_ms"] == [410, 420])
        #expect(r.endLoads.count == 2)
        #expect(r.heavyAtEnd)
        #expect(r.skippedRuns == ["heavy"])
    }
}
