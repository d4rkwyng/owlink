import Foundation

// The daily-use pass (CEDRIC_CHECK=dailyuse, Scripts/daily-use.sh,
// docs/daily-use.md): the pure parts, kept here so they are unit-tested
// (Tests/CedricCoreTests/DailyUseTests.swift). The app side drives the
// flows (Sources/CedricApp/DailyUseCheck.swift).

/// One assertion the pass made.
public struct DailyUseAssertion: Equatable, Sendable {
    public var name: String
    public var passed: Bool
    public var detail: String

    public init(_ name: String, passed: Bool, detail: String = "") {
        self.name = name
        self.passed = passed
        self.detail = detail
    }
}

/// What a plain assertion or a known-bug group comes to.
public enum DailyUseOutcome: Equatable, Sendable {
    case pass(String)
    case fail(String, detail: String)
    /// A known bug still fails, as expected: a pass with a note.
    case knownBug(id: String, detail: String)
    /// Everything inside a known-bug marker passed: the bug is fixed and
    /// the marker must go (XCTExpectFailure(strict: true)).
    case unexpectedPass(id: String)
    case skip(String, reason: String)

    /// Counts against the run (exit 1).
    public var isFailure: Bool {
        switch self {
        case .fail, .unexpectedPass: return true
        case .pass, .knownBug, .skip: return false
        }
    }

    /// The line the check prints (Scripts/daily-use.sh greps these).
    public var line: String {
        switch self {
        case .pass(let n): return "check: PASS \(n)"
        case .fail(let n, let d): return d.isEmpty ? "check: FAIL \(n)" : "check: FAIL \(n) \(d)"
        case .knownBug(let id, let d): return "check: KNOWN-BUG \(id) (still open: \(d))"
        case .unexpectedPass(let id): return "check: FAIL UNEXPECTED-PASS \(id): the bug is fixed, remove the knownBug marker"
        case .skip(let n, let r): return "check: SKIP \(n): \(r)"
        }
    }
}

/// The verdict rules, XCTExpectFailure(strict: true) style.
public enum DailyUseVerdict {
    /// A plain assertion: pass or fail.
    public static func plain(_ a: DailyUseAssertion) -> DailyUseOutcome {
        a.passed ? .pass(a.name) : .fail(a.name, detail: a.detail)
    }

    /// The assertions made inside a known-bug marker. Any failing: the
    /// bug is still open (a note; the failing ones named). All passing:
    /// an unexpected pass, a failure until the marker is removed. None
    /// made: a failure too (the marker guards nothing, the flow broke).
    public static func knownBug(id: String, note: String, _ assertions: [DailyUseAssertion]) -> DailyUseOutcome {
        guard !assertions.isEmpty else {
            return .fail("known-bug \(id)", detail: "no assertions ran inside the marker (\(note))")
        }
        let failing = assertions.filter { !$0.passed }
        guard !failing.isEmpty else { return .unexpectedPass(id: id) }
        let what = failing.map { $0.detail.isEmpty ? $0.name : "\($0.name): \($0.detail)" }.joined(separator: "; ")
        return .knownBug(id: id, detail: note.isEmpty ? what : "\(note); \(what)")
    }
}

/// The pass's totals.
public struct DailyUseTally: Equatable, Sendable {
    public var passed = 0, failed = 0, knownBugs = 0, skipped = 0

    public init() {}

    public mutating func add(_ o: DailyUseOutcome) {
        switch o {
        case .pass: passed += 1
        case .fail, .unexpectedPass: failed += 1
        case .knownBug: knownBugs += 1
        case .skip: skipped += 1
        }
    }

    /// 0 only with no failure and at least one pass or known bug.
    public var exitCode: Int32 { failed == 0 && passed + knownBugs > 0 ? 0 : 1 }

    public var summary: String {
        "check: done \(passed) passed, \(failed) failed, \(knownBugs) known bugs, \(skipped) skipped"
    }
}

// MARK: Speed budgets

/// The machine's load, as `sysctl vm.loadavg` and the core count give it.
public struct DailyUseLoad: Equatable, Sendable {
    public var oneMinute: Double
    public var cores: Int

    public init(oneMinute: Double, cores: Int) {
        self.oneMinute = oneMinute
        self.cores = max(cores, 1)
    }

    public var perCore: Double { oneMinute / Double(cores) }

    /// Over this 1-minute load per core, timings are not trusted.
    public static let heavyPerCore = 0.75

    public func isHeavy(threshold: Double = DailyUseLoad.heavyPerCore) -> Bool { perCore > threshold }

    public var text: String { String(format: "load %.2f, cores %d", oneMinute, cores) }
}

/// One metric's budget, as Scripts/daily-use-budgets.json stores it.
public struct DailyUseBudgetEntry: Codable, Equatable, Sendable {
    public var baseline_ms: Double
    public var budget_ms: Double
    public var cap_ms: Double
    public var floor_ms: Double
    /// The per-run medians the baseline is the median of.
    public var runs_ms: [Double]

    public init(baseline_ms: Double, budget_ms: Double, cap_ms: Double, floor_ms: Double, runs_ms: [Double]) {
        self.baseline_ms = baseline_ms
        self.budget_ms = budget_ms
        self.cap_ms = cap_ms
        self.floor_ms = floor_ms
        self.runs_ms = runs_ms
    }
}

/// Scripts/daily-use-budgets.json.
public struct DailyUseBudgetFile: Codable, Equatable, Sendable {
    public var measured: String
    public var host: String
    public var notes: [String]
    public var metrics: [String: DailyUseBudgetEntry]

    public init(measured: String, host: String, notes: [String], metrics: [String: DailyUseBudgetEntry]) {
        self.measured = measured
        self.host = host
        self.notes = notes
        self.metrics = metrics
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self) + Data("\n".utf8)
    }

    public static func decode(_ data: Data) throws -> DailyUseBudgetFile {
        try JSONDecoder().decode(DailyUseBudgetFile.self, from: data)
    }
}

public enum DailyUseBudget {
    /// The metrics, and for each the floor (no budget is tighter: a tiny
    /// baseline plus 30% is noise) and the cap (no budget is looser,
    /// whatever the baseline: past it the app is slow, full stop), in ms.
    public static let limits: [String: (floor: Double, cap: Double)] = [
        "cold_launch_ms": (floor: 300, cap: 1500),
        "sidebar_md_ms": (floor: 40, cap: 250),
        "sidebar_log_ms": (floor: 80, cap: 600),
        "sidebar_switch_ms": (floor: 30, cap: 200),
        "preview_toggle_ms": (floor: 80, cap: 600),
    ]

    public static func median(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        let s = xs.sorted()
        let m = s.count / 2
        return s.count % 2 == 1 ? s[m] : (s[m - 1] + s[m]) / 2
    }

    /// Baseline + 30%, at least `floor`, at most `cap`.
    public static func budget(baseline: Double, floor: Double, cap: Double) -> Double {
        min(max(baseline * 1.3, floor), cap)
    }

    /// The samples of one launch, the first (warm-up) left out.
    public static func measured(_ samples: [Double]) -> [Double] { Array(samples.dropFirst()) }

    /// A budget entry from each run's median (the baseline: their median).
    public static func entry(metric: String, runMedians: [Double]) -> DailyUseBudgetEntry? {
        guard let base = median(runMedians) else { return nil }
        let l = limits[metric] ?? (floor: 0, cap: .infinity)
        let r = { (x: Double) in (x * 10).rounded() / 10 }
        return DailyUseBudgetEntry(baseline_ms: r(base), budget_ms: r(budget(baseline: base, floor: l.floor, cap: l.cap)),
                                   cap_ms: l.cap, floor_ms: l.floor, runs_ms: runMedians.map(r))
    }

    /// A metric's verdict: the median of its samples (the per-run medians;
    /// each cold launch) against its budget. The load excuses a metric only
    /// through that metric's own samples (the attribution rule): over
    /// budget is a SKIP when every sample came from a run under heavy load,
    /// or when the calm samples alone are within budget (the heavy runs
    /// pushed the median over). Calm samples over budget on their own are
    /// a FAIL, whatever the load was in other runs or for other metrics.
    public static func evaluate(metric: String, samples: [DailyUseSample], entry: DailyUseBudgetEntry?) -> DailyUseOutcome {
        guard let value = median(samples.map(\.value)) else { return .skip(metric, reason: "no samples") }
        guard let entry else { return .skip(metric, reason: String(format: "no budget yet (measured %.1f ms)", value)) }
        let limit = min(entry.budget_ms, entry.cap_ms)
        let what = String(format: "%.1f ms, budget %.1f ms (baseline %.1f, cap %.0f)", value, limit, entry.baseline_ms, entry.cap_ms)
        if value <= limit { return .pass("\(metric) \(what)") }
        let calm = samples.filter { !$0.heavy }.map(\.value)
        let heavy = samples.count - calm.count
        guard let calmMedian = median(calm) else {
            return .skip(metric, reason: "over budget under load: all \(samples.count) of its samples are from runs under heavy load (\(what))")
        }
        if heavy > 0, calmMedian <= limit {
            return .skip(metric, reason: String(format: "over budget under load: %d of its %d samples are from runs under heavy load, the calm ones alone are within budget at %.1f ms (%@)",
                                                heavy, samples.count, calmMedian, what))
        }
        let detail = heavy == 0 ? what : String(format: "%@; its %d calm samples alone: %.1f ms", what, calm.count, calmMedian)
        return .fail("\(metric) over budget", detail: detail)
    }

    /// The new budgets file for `--write-budgets`, or why there is none.
    /// A collection is complete when every metric asked for has exactly
    /// the samples asked for (`runs` per perf metric, `cold` cold
    /// launches), no perf launch failed or was skipped, and none of those
    /// samples is from a run under heavy load (a baseline measured loaded
    /// loosens the budget). Metrics not in `metrics` keep their old entry.
    public static func baselines(from r: DailyUseResults, metrics: [String], runs: Int, cold: Int, old: DailyUseBudgetFile?,
                                 measured: String, host: String, notes: [String]) -> Result<DailyUseBudgetFile, DailyUseIncomplete> {
        var problems: [String] = []
        var entries = old?.metrics ?? [:]
        if metrics.isEmpty { problems.append("no metrics asked for") }
        for m in metrics where limits[m] == nil { problems.append("\(m) is not a metric") }
        let perf = metrics.contains { $0 != coldMetric }
        if perf, !r.failedRuns.isEmpty { problems.append("perf launches failed: runs \(r.failedRuns.joined(separator: ", "))") }
        if perf, !r.skippedRuns.isEmpty { problems.append("perf launches skipped: \(r.skippedRuns.joined(separator: ", "))") }
        for m in metrics where limits[m] != nil {
            let samples = r.samples[m] ?? []
            let want = m == coldMetric ? cold : runs
            if samples.count != want || want < 1 { problems.append("\(m) has \(samples.count) of \(want) samples") }
            let heavy = samples.filter(\.heavy).count
            if heavy > 0 { problems.append("\(m) has \(heavy) samples from runs under heavy load") }
            if let e = entry(metric: m, runMedians: samples.map(\.value)) { entries[m] = e }
        }
        for m in limits.keys.sorted() where entries[m] == nil { problems.append("\(m) would have no entry") }
        guard problems.isEmpty else { return .failure(DailyUseIncomplete(problems: problems)) }
        let partial = Set(metrics) != Set(limits.keys)
        let kept = partial ? (old?.notes ?? []) : []
        let added = partial ? notes.map { "\(measured) \(metrics.sorted().joined(separator: ",")): \($0)" } : notes
        return .success(DailyUseBudgetFile(measured: measured, host: host, notes: kept + added, metrics: entries))
    }

    /// Replaces the budgets file at `url` only with a complete collection
    /// (`baselines`); otherwise the file is left as it is, byte for byte.
    @discardableResult
    public static func writeBaselines(from r: DailyUseResults, metrics: [String], runs: Int, cold: Int, to url: URL,
                                      measured: String, host: String, notes: [String]) throws -> DailyUseBudgetFile {
        let old = (try? Data(contentsOf: url)).flatMap { try? DailyUseBudgetFile.decode($0) }
        let file = try baselines(from: r, metrics: metrics, runs: runs, cold: cold, old: old, measured: measured, host: host, notes: notes).get()
        try file.encoded().write(to: url, options: .atomic)
        return file
    }

    public static let coldMetric = "cold_launch_ms"
}

/// Why `--write-budgets` wrote nothing.
public struct DailyUseIncomplete: Error, Equatable, Sendable {
    public var problems: [String]
}

/// One value a verdict is made of (a perf launch's median of a metric, or
/// one cold launch) and whether the run it is from was under heavy load.
public struct DailyUseSample: Equatable, Sendable {
    public var value: Double
    public var heavy: Bool

    public init(_ value: Double, heavy: Bool = false) {
        self.value = value
        self.heavy = heavy
    }
}

/// What the launches printed, as Scripts/daily-use.sh collects it:
///   run=N metric=NAME value=MS      one perf launch's median of a metric
///   run=N load_start=X load_end=Y cores=C
///   run=N skipped=REASON            the launch measured nothing (heavy load)
///   run=N failed=1                  the launch printed a FAIL (or no summary)
///   cold=N value=MS load_start=X load_end=Y cores=C    one cold launch (launch_ms)
/// A sample is heavy when its own run's load was heavy at its start or
/// end: a perf launch's load marks that launch's metrics only, a cold
/// launch's load that launch only.
public struct DailyUseResults: Equatable, Sendable {
    public var samples: [String: [DailyUseSample]] = [:]
    public var skippedRuns: [String] = []
    public var failedRuns: [String] = []
    /// Each perf launch's load, by run.
    public var runLoads: [String: [DailyUseLoad]] = [:]

    public init() {}

    public var runMedians: [String: [Double]] { samples.mapValues { $0.map(\.value) } }

    public static func parse(_ text: String) -> DailyUseResults {
        var r = DailyUseResults()
        var perRun: [(run: String, metric: String, value: Double)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            var kv: [String: String] = [:]
            for w in line.split(separator: " ") {
                guard let eq = w.firstIndex(of: "=") else { if w == "cold" { kv["cold"] = "" }; continue }
                kv[String(w[..<eq])] = String(w[w.index(after: eq)...])
            }
            let cores = kv["cores"].flatMap(Int.init)
            let loads = ["load_start", "load_end"].compactMap { k in
                kv[k].flatMap(Double.init).flatMap { l in cores.map { DailyUseLoad(oneMinute: l, cores: $0) } }
            }
            if kv["cold"] != nil {
                if let v = kv["value"].flatMap(Double.init) {
                    r.samples[DailyUseBudget.coldMetric, default: []].append(DailyUseSample(v, heavy: loads.contains { $0.isHeavy() }))
                }
                continue
            }
            guard let run = kv["run"] else { continue }
            if let reason = kv["skipped"] { r.skippedRuns.append(reason); continue }
            if kv["failed"] != nil { r.failedRuns.append(run); continue }
            if let m = kv["metric"], let v = kv["value"].flatMap(Double.init) { perRun.append((run, m, v)) }
            if !loads.isEmpty { r.runLoads[run, default: []] += loads }
        }
        for s in perRun {
            r.samples[s.metric, default: []].append(DailyUseSample(s.value, heavy: (r.runLoads[s.run] ?? []).contains { $0.isHeavy() }))
        }
        return r
    }
}
