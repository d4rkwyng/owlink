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

    /// A metric's verdict: its value (the median of the per-run medians)
    /// against its budget. Over budget with the load heavy at the end of
    /// a run: a SKIP, not a FAIL (no flaky red).
    public static func evaluate(metric: String, value: Double?, entry: DailyUseBudgetEntry?, heavyAtEnd: Bool) -> DailyUseOutcome {
        guard let value else { return .skip(metric, reason: "no samples") }
        guard let entry else { return .skip(metric, reason: String(format: "no budget yet (measured %.1f ms)", value)) }
        let limit = min(entry.budget_ms, entry.cap_ms)
        let what = String(format: "%.1f ms, budget %.1f ms (baseline %.1f, cap %.0f)", value, limit, entry.baseline_ms, entry.cap_ms)
        if value <= limit { return .pass("\(metric) \(what)") }
        if heavyAtEnd { return .skip(metric, reason: "over budget under load (\(what))") }
        return .fail("\(metric) over budget", detail: what)
    }
}

/// What the perf launches printed, as Scripts/daily-use.sh collects it:
///   run=N metric=NAME value=MS      one launch's median of a metric
///   run=N load_start=X load_end=Y cores=C
///   run=N skipped=REASON            the launch measured nothing (heavy load)
///   cold value=MS                   one cold launch (launch_ms)
public struct DailyUseResults: Equatable, Sendable {
    public var runMedians: [String: [Double]] = [:]
    public var endLoads: [DailyUseLoad] = []
    public var skippedRuns: [String] = []

    public init() {}

    public static func parse(_ text: String) -> DailyUseResults {
        var r = DailyUseResults()
        for line in text.split(whereSeparator: \.isNewline) {
            var kv: [String: String] = [:]
            var words = line.split(separator: " ").map(String.init)
            if words.first == "cold" { words.removeFirst(); kv["metric"] = "cold_launch_ms" }
            for w in words {
                guard let eq = w.firstIndex(of: "=") else { continue }
                kv[String(w[..<eq])] = String(w[w.index(after: eq)...])
            }
            if let reason = kv["skipped"] { r.skippedRuns.append(reason); continue }
            if let m = kv["metric"], let v = kv["value"].flatMap(Double.init) { r.runMedians[m, default: []].append(v) }
            if let e = kv["load_end"].flatMap(Double.init), let c = kv["cores"].flatMap(Int.init) {
                r.endLoads.append(DailyUseLoad(oneMinute: e, cores: c))
            }
        }
        return r
    }

    /// Heavy at the end of any perf launch.
    public var heavyAtEnd: Bool { endLoads.contains { $0.isHeavy() } }
}
