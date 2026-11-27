import Foundation
import Testing

// Swift's cooperative pool has one thread per core: three on a CI runner.
// A test that blocks one of them (waiting on git, zip or openssl, or a
// second of CPU work on a big document) takes it from every other test, and
// a few of those at once stall the whole run: every test, timing tests
// included, then absorbs the wait (release run 44409932572: 573 tests at
// ~5.7 s). Tests marked `.offPool` run on GCD threads instead, which the
// system adds more of while one is blocked. What they check is unchanged.

@available(macOS 15, *)
final class OffPoolExecutor: TaskExecutor, @unchecked Sendable {
    static let shared = OffPoolExecutor()
    // .default, the QoS the tests themselves run at (TaskPriority.medium):
    // at .userInitiated this CPU work went ahead of every other test and of
    // URLSession's own threads, and made the request timing tests late
    // (runs 44449227211, 44452609801).
    private let queue = DispatchQueue(label: "cedric.tests.off-pool", qos: .default, attributes: .concurrent)

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}

/// Runs each test it covers (on a suite: every test in it) with the
/// off-pool executor as its task executor, so the test's own synchronous
/// body runs there and task-locals (the current test, for `#expect`) stay.
struct OffPoolTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        if testCase != nil, #available(macOS 15, *) {
            try await withTaskExecutorPreference(OffPoolExecutor.shared) { try await function() }
        } else {
            try await function()
        }
    }
}

extension Trait where Self == OffPoolTrait {
    /// Blocking or CPU-heavy: keep it off Swift's cooperative pool.
    static var offPool: Self { .init() }
}

/// Runs `body` on a thread of its own with the main thread's 8 MB stack and
/// returns its result: off the main actor and off the cooperative pool, for
/// CPU-heavy work that also recurses deep. GCD's and the pool's threads have
/// 512 KB, which a debug build's `JSONFormatter` overflows at a few hundred
/// levels (release needs under 128 KB at its 511-level cap). `body` runs
/// without the test's task-locals: return values and `#expect` on them
/// after the await.
func onLargeStack<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
        let t = Thread { c.resume(returning: body()) }
        t.stackSize = 8 << 20
        t.start()
    }
}
