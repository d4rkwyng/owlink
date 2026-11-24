import Foundation
import CedricCore

// MARK: - Who is asking

/// Why the built-in model is being asked for. Only an explicit request
/// (or the "Load model at launch" opt-in) may load it into memory; an
/// automatic one may only use a model already in memory.
///
/// A freeze on an M5 Max (GPU and WindowServer hung, power-button reset)
/// came from the first in-process load of Qwen3 4B, which the automatic
/// owl-hint check started about ten seconds after a file was opened. So
/// opening, saving, typing or idling never loads the model any more.
public enum BuiltInLoadIntent: Sendable, Equatable {
    /// A timer, an edit, a scroll, a save, automatic AI grammar: anything
    /// the user didn't ask for just now. The default.
    case automatic
    /// Ask Cedric, Review, Ask AI Now, Check Grammar with Cedric, Check
    /// Script for Risks, Test Connection.
    case userAsked
    /// "Load model at launch" (`LocalAISettings.loadModelAtLaunch`), on.
    case launch
}

public enum BuiltInLoad {
    /// The intent of the current task (and every task it creates with
    /// `Task {}` or a task group). Unmarked work counts as automatic, so
    /// a path nobody thought about can never load the model.
    @TaskLocal public static var intent: BuiltInLoadIntent = .automatic

    /// Runs `body` as something the user asked for.
    public static func userAsked<T>(_ body: () async throws -> T) async rethrows -> T {
        try await $intent.withValue(.userAsked, operation: body)
    }
}

// MARK: - Watchdog

/// How long a built-in model load may take before the engine is marked
/// unhealthy for the session. The load is `llama_model_load_from_file`,
/// `llama_init_from_model` and a one-token warm-up decode (the first
/// decode, where Metal builds its pipelines), all in `LlamaRuntime.load`.
///
/// 60 seconds. A healthy Apple-silicon load of the default Qwen3 4B
/// (2.5 GB, mmapped, every layer on Metal) is a few seconds and well under
/// 20 even cold. Intel Macs run on the CPU and read the whole file into
/// RAM; 60 s leaves them room without a false alarm. A load still not back
/// after a minute is not a slow disk: it is stuck, and asking again would
/// only stack a second load behind it on llama.cpp's one queue.
///
/// n_ctx is set inside the timed section (`llama_init_from_model`), so a
/// context sized differently (PR #9 sizes it from RAM) is covered the same
/// way; nothing here depends on its value.
public enum BuiltInWatchdog {
    public static let seconds: TimeInterval = 60

    /// The value of `task`, or `BuiltInError.loadTimedOut` after `seconds`
    /// on `clock`, whichever comes first. Never waits for a stuck `task`
    /// (it is unstructured; awaiting it in a task group would), and never
    /// cancels it: the caller decides.
    static func race<T: Sendable>(_ task: Task<T, Error>, seconds: TimeInterval, clock: any OwlClock) async throws -> T {
        let once = Once<T>()
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            once.set(c)
            let timer = Task {
                do { try await clock.sleep(seconds: seconds) } catch { return }
                once.resume(.failure(BuiltInError.loadTimedOut(seconds: Int(seconds))))
            }
            Task {
                let r = await task.result
                timer.cancel()
                once.resume(r)
            }
        }
    }

    private final class Once<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var c: CheckedContinuation<T, Error>?
        func set(_ c: CheckedContinuation<T, Error>) { lock.withLock { self.c = c } }
        func resume(_ r: Result<T, Error>) {
            let c: CheckedContinuation<T, Error>? = lock.withLock { defer { self.c = nil }; return self.c }
            c?.resume(with: r)
        }
    }
}

// MARK: - This session

/// What this process knows about the built-in engine: whether the user
/// (or the launch opt-in) has loaded a model, and whether a load hung.
/// Lives as long as the host (`BuiltInModelHost.shared`: the process), so
/// closing a document keeps it and quitting forgets it. Read from any
/// thread; the host writes it.
public final class BuiltInSession: @unchecked Sendable {
    public struct Unhealthy: Sendable, Equatable {
        /// The watchdog's limit that was passed.
        public var seconds: Int
    }

    private let lock = NSLock()
    private var _loaded = false
    private var _inMemory = false
    private var _unhealthy: Unhealthy?
    private var _retryUsed = false

    public init() {}

    /// A model was loaded this session by an explicit request or by the
    /// launch opt-in (it may have been unloaded since).
    public var explicitlyLoaded: Bool { lock.withLock { _loaded } }
    /// A model is in memory now. Automatic checks never load one, so after
    /// an idle unload they wait (rules-only) until the user asks again.
    public var modelInMemory: Bool { lock.withLock { _inMemory } }
    /// A load or its first decode passed the watchdog this session.
    public var unhealthy: Unhealthy? { lock.withLock { _unhealthy } }
    /// Automatic checks may ask the built-in engine: a model is in memory
    /// and no load hung.
    public var allowsAutomatic: Bool { lock.withLock { _inMemory && _unhealthy == nil } }

    func markLoaded() {
        lock.withLock { _loaded = true; _inMemory = true; _unhealthy = nil; _retryUsed = false }
    }

    func markUnloaded() { lock.withLock { _inMemory = false } }

    func markUnhealthy(seconds: Int) {
        lock.withLock { _unhealthy = Unhealthy(seconds: seconds) }
    }

    /// An explicit request after the watchdog fired: true once (the
    /// retry), then false until the app is restarted.
    func takeRetry() -> Bool {
        lock.withLock {
            guard !_retryUsed else { return false }
            _retryUsed = true
            return true
        }
    }
}

extension Notification.Name {
    /// Posted on the main queue when the built-in model did not finish
    /// loading in time (`BuiltInWatchdog`). userInfo["seconds"]: Int.
    public static let cedricBuiltInModelUnhealthy = Notification.Name("CedricBuiltInModelUnhealthy")
}

/// Providers whose automatic use has a precondition (the built-in engine:
/// `BuiltInSession.allowsAutomatic`). `OwlScheduler` asks before an
/// automatic request; asked-for checks don't.
public protocol OwlAutomaticGate: Sendable {
    var allowsAutomaticRequests: Bool { get }
    /// Automatic use is off because the engine hung this session.
    var isUnhealthy: Bool { get }
}

/// Providers that can load their model ahead of the first request
/// ("Load model at launch").
public protocol OwlPreloadingProvider: Sendable {
    func preload() async throws
}
