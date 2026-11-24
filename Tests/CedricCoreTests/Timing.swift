import Foundation

/// Speed bounds that hold on a slow CI runner and still catch a slow-down
/// in the code.
///
/// The wall clock alone can't tell the two apart. On a busy runner it also
/// counts the wait for a core. On GitHub's macos-26 runner (run 45258714905)
/// even the best of 7 tries came out 4–30 times slower than on a dev Mac.
/// So these bounds use two things instead:
/// - This thread's CPU time, which leaves out the time the thread was
///   waiting for a core.
/// - A fixed reference workload, timed on the same thread right before each
///   try. If the machine itself is slower (slower cores, or a VM losing time
///   to its host), the reference slows down too, and the budget grows by the
///   same factor. It never shrinks below the plain budget.
///
/// A real slow-down in the code under test makes it slower than the
/// reference, so the ratio still catches it. Each test also keeps a wide
/// wall-clock bound as a guard against a blow-up.
enum Timing {
    /// CPU seconds this thread has run so far.
    static func threadCPU() -> Double { Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)) / 1e9 }

    /// Monotonic wall-clock seconds (not `Date`, which jumps when the
    /// system clock is set), for the blow-up guards.
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    /// About 1 ms of CPU for the reference in a debug build on an M-series
    /// dev Mac: the best of 3 tries came out at 0.95–1.0 ms there.
    static let referenceNominal = 0.001

    private static let referenceText = String(repeating: "let value = items[index] // a \"quoted\" note, 42 times\n", count: 400)
    private static let referenceRegex = try! NSRegularExpression(pattern: #"\b[a-z]+\b|"[^"]*"|\d+"#)

    /// The reference: the kind of work these tests time (a regex over a
    /// few KB, and Swift string handling of each line). Returns CPU seconds.
    static func reference() -> Double {
        let start = threadCPU()
        let ns = referenceText as NSString
        var n = referenceRegex.numberOfMatches(in: referenceText, range: NSRange(location: 0, length: ns.length))
        for line in referenceText.split(separator: "\n") {
            n += line.trimmingCharacters(in: .whitespaces).lowercased().filter { $0 == "a" }.count
        }
        let took = threadCPU() - start
        precondition(n > 0)
        return took
    }

    /// How many times slower than the dev Mac this thread runs right now
    /// (at least 1): the best of 3 runs of the reference.
    static func slowdown() -> Double {
        max(1, (0..<3).map { _ in reference() }.min()! / referenceNominal)
    }

    struct Result {
        /// The best try's CPU seconds divided by the slowdown measured just
        /// before it: what to hold to the budget.
        var scaled: Double
        /// The best try's CPU seconds and wall-clock seconds (the same try).
        var cpu: Double, wall: Double
        /// The slowdown the best try was scaled by.
        var slowdown: Double

        var description: String {
            String(format: "%.2f ms scaled (%.2f ms CPU, slowdown %.1f×, wall %.2f ms)", scaled * 1000, cpu * 1000, slowdown, wall * 1000)
        }
    }

    /// Runs `work` `tries` times on this thread. Measures the slowdown just
    /// before each run.
    static func best(of tries: Int, _ work: () -> Void) -> Result {
        var result = Result(scaled: .infinity, cpu: .infinity, wall: .infinity, slowdown: 1)
        for _ in 0..<tries {
            let factor = slowdown()
            let wallStart = now(), cpuStart = threadCPU()
            work()
            let cpu = threadCPU() - cpuStart, wall = now() - wallStart
            if cpu / factor < result.scaled { result = Result(scaled: cpu / factor, cpu: cpu, wall: wall, slowdown: factor) }
        }
        return result
    }
}
