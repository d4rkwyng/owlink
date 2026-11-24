import Foundation
import CedricCore

/// One prompt for the built-in engine: chat messages in, text out.
public struct GenerationRequest: Sendable, Equatable {
    public var system: String
    public var user: String
    public var maxTokens: Int
    /// A GBNF grammar the output must follow (llama.cpp), or nil.
    public var grammar: String?
    /// A whole conversation (Ask Cedric): when set, it replaces `system`
    /// and `user` (roles "system", "user", "assistant").
    public var messages: [ChatMessage]?

    public init(system: String, user: String, maxTokens: Int = 320, grammar: String? = nil) {
        self.system = system; self.user = user; self.maxTokens = maxTokens; self.grammar = grammar
    }

    public init(messages: [ChatMessage], maxTokens: Int, grammar: String? = nil) {
        self.system = messages.first { $0.role == "system" }?.content ?? ""
        self.user = messages.last { $0.role == "user" }?.content ?? ""
        self.messages = messages; self.maxTokens = maxTokens; self.grammar = grammar
    }

    /// The conversation to format: `messages`, else system + user.
    public var conversation: [ChatMessage] {
        messages ?? [ChatMessage(role: "system", content: system), ChatMessage(role: "user", content: user)]
    }
}

public struct GenerationResult: Sendable, Equatable {
    public var text: String
    /// The whole prompt, in tokens.
    public var promptTokens: Int
    /// Of those, the leading tokens already in the KV cache from the
    /// previous request (not processed again); 0 when it was cleared.
    public var reusedTokens: Int
    public var completionTokens: Int
    /// Prompt processing (prefill) time.
    public var promptSeconds: TimeInterval
    /// Token generation time.
    public var generateSeconds: TimeInterval

    public init(text: String, promptTokens: Int = 0, completionTokens: Int = 0,
                promptSeconds: TimeInterval = 0, generateSeconds: TimeInterval = 0, reusedTokens: Int = 0) {
        self.text = text; self.promptTokens = promptTokens; self.completionTokens = completionTokens
        self.reusedTokens = reusedTokens
        self.promptSeconds = promptSeconds; self.generateSeconds = generateSeconds
    }

    public var tokensPerSecond: Double {
        generateSeconds > 0 ? Double(completionTokens) / generateSeconds : 0
    }
}

public enum BuiltInError: Error, Equatable, Sendable {
    case notInstalled
    case loadFailed(String)
    case promptTooLong(tokens: Int, limit: Int)
    case generationFailed(String)
    case cancelled
    /// An automatic check asked while no model was in memory (before any
    /// explicit load, or after an idle unload; `BuiltInLoadIntent`):
    /// nothing was loaded.
    case automaticLoadNotAllowed
    /// The load (or its first decode) did not return within the
    /// watchdog's limit (`BuiltInWatchdog`).
    case loadTimedOut(seconds: Int)
    /// An earlier load hung this session; the engine is not loaded again
    /// until the user retries (once) or restarts.
    case unhealthy
    /// The user asked while a load the watchdog gave up on is still
    /// running: no second load starts, and the one retry is kept for
    /// when it has stopped.
    case stillLoading
}

/// The inference library behind the built-in engine (llama.cpp in the app,
/// a fake in tests).
public protocol BuiltInRuntime: Sendable {
    func load(modelAt url: URL) async throws -> any LoadedModel
}

/// A model in memory. `generate` calls are serialised by the implementation.
public protocol LoadedModel: AnyObject, Sendable {
    func generate(_ request: GenerationRequest) async throws -> GenerationResult
    /// The same, calling `onText` with each new piece of text as it is
    /// generated (whole UTF-8 characters only). Default: all at the end.
    func generate(_ request: GenerationRequest, onText: @escaping @Sendable (String) -> Void) async throws -> GenerationResult
    /// Frees the weights and context. Called once, after the last generate.
    func unload()
}

extension LoadedModel {
    public func generate(_ request: GenerationRequest, onText: @escaping @Sendable (String) -> Void) async throws -> GenerationResult {
        let r = try await generate(request)
        onText(r.text)
        return r
    }
}

/// Keeps at most one built-in model in memory: loads it on the first
/// request, swaps it when a different model is asked for, and unloads it
/// after `idleTimeout` (default 5 minutes) without a request, to give the
/// RAM back. Never unloads during a generation.
///
/// Who may load (`BuiltInLoad.intent`): a request the user made, or the
/// "Load model at launch" opt-in. An automatic request may only use a
/// model that is already in memory; it never loads one (not the first
/// time, not after an idle unload, not a different model) and gets
/// `BuiltInError.automaticLoadNotAllowed` instead. After an idle unload,
/// automatic hints are rules-only until the user asks again or the
/// launch opt-in loads the model.
///
/// Every load runs under a watchdog (`loadTimeout`, `BuiltInWatchdog`). If
/// it fires, the engine is unhealthy for the session: automatic requests
/// never load again, the user's next request may retry once, and no second
/// load starts while the stuck one is still running (a request then gets
/// `BuiltInError.stillLoading` and the retry is kept for later).
public actor BuiltInModelHost {
    public static let defaultIdleTimeout: TimeInterval = 300

    /// The app's one host, so every provider shares the loaded model.
    /// Debug builds only: CEDRIC_BUILTIN_SPY=1 swaps llama.cpp for
    /// `SpyBuiltInRuntime` (the owl checks of the load gate, which must not
    /// load a real model even if the gate were broken).
    public static let shared: BuiltInModelHost = {
        #if DEBUG
        if DevEnvironment.values["CEDRIC_BUILTIN_SPY"] == "1" { return BuiltInModelHost(runtime: SpyBuiltInRuntime.shared) }
        #endif
        return BuiltInModelHost(runtime: LlamaRuntime())
    }()

    let runtime: any BuiltInRuntime
    let clock: any OwlClock
    public private(set) var idleTimeout: TimeInterval
    public nonisolated let loadTimeout: TimeInterval
    /// This process's record of explicit loads and hung ones.
    public nonisolated let session: BuiltInSession

    private var loaded: (path: URL, model: any LoadedModel)?
    /// The one load under way. A request for another model waits for it
    /// to end before starting its own, so two loads are never in flight
    /// and only one can publish (`model(at:)`).
    private var loading: (attempt: Int, path: URL, task: Task<any LoadedModel, Error>)?
    /// A load the watchdog gave up on that has not returned yet, by
    /// attempt. While it is set nothing else is loaded (llama.cpp has one
    /// queue: a second load would only wait behind it).
    private var stuck: (attempt: Int, task: Task<any LoadedModel, Error>)?
    private var active = 0
    private var lastUse: TimeInterval = 0
    private var idleTimer: Task<Void, Never>?
    /// For tests and the log.
    public private(set) var loadCount = 0
    public private(set) var unloadCount = 0
    /// Loads started (including ones that failed or hung), for tests.
    public private(set) var loadAttempts = 0
    /// Automatic requests turned away without loading, for tests.
    public private(set) var refusedAutomatic = 0

    public init(runtime: any BuiltInRuntime, clock: any OwlClock = SystemClock(),
                idleTimeout: TimeInterval = BuiltInModelHost.defaultIdleTimeout,
                loadTimeout: TimeInterval = BuiltInWatchdog.seconds,
                session: BuiltInSession = BuiltInSession()) {
        self.runtime = runtime
        self.clock = clock
        self.idleTimeout = idleTimeout
        self.loadTimeout = loadTimeout
        self.session = session
    }

    public var loadedPath: URL? { loaded?.path }
    /// A load the watchdog gave up on is still running.
    public var hasStuckLoad: Bool { stuck != nil }

    public func setIdleTimeout(_ seconds: TimeInterval) {
        idleTimeout = seconds
        armIdleTimer()
    }

    public func generate(modelAt path: URL, _ request: GenerationRequest,
                         onText: (@Sendable (String) -> Void)? = nil) async throws -> GenerationResult {
        active += 1
        defer {
            active -= 1
            lastUse = clock.now
            armIdleTimer()
        }
        let model = try await model(at: path)
        try Task.checkCancellation()
        if let onText { return try await model.generate(request, onText: onText) }
        return try await model.generate(request)
    }

    /// "Load model at launch": loads (under the watchdog) without a
    /// request, as `BuiltInLoadIntent.launch`. The idle timer applies.
    public func preload(modelAt path: URL) async throws {
        active += 1
        defer {
            active -= 1
            lastUse = clock.now
            armIdleTimer()
        }
        _ = try await BuiltInLoad.$intent.withValue(.launch) { try await self.model(at: path) }
    }

    /// Loads (or reuses) the model at `path`, dropping any other one.
    /// Refuses an automatic request unless the model is already in memory,
    /// and any request while the engine is unhealthy (except one explicit
    /// retry, once the stuck load has stopped).
    ///
    /// One load at a time. A request for a different model while one is
    /// loading waits for that load to end (loaded, failed or given up on
    /// by the watchdog), then looks again. Before 0.5.4 it started a second
    /// load: if both finished, the second dropped the first model without
    /// unloading it (llama.cpp's exit registry still held it), and if both
    /// hung, each replaced the watchdog's record of the stuck load and
    /// either one finishing cleared it while the other still ran.
    public func model(at path: URL) async throws -> any LoadedModel {
        let intent = BuiltInLoad.intent
        while true {
            if let loaded, loaded.path == path { return loaded.model }
            try admit(intent)
            guard let other = loading else { break }
            if other.path == path { return try await other.task.value }
            // Ends after that load's bookkeeping (`runLoad`): `loading` is
            // clear and its model published or its stuck load recorded.
            _ = await other.task.result
            try Task.checkCancellation()
        }
        // No suspension from here to `loading` being set: this is the one load.
        if let old = loaded { drop(old) }
        loadAttempts += 1
        let attempt = loadAttempts
        // Actor-isolated: it can't start before `loading` is set below.
        let task = Task { try await self.runLoad(attempt: attempt, path: path) }
        loading = (attempt, path, task)
        return try await task.value
    }

    /// Load attempt `attempt`, under the watchdog: publishes the model, or
    /// records the stuck load, then clears `loading`, all before anyone
    /// waiting on it resumes.
    private func runLoad(attempt: Int, path: URL) async throws -> any LoadedModel {
        defer { if loading?.attempt == attempt { loading = nil } }
        let runtime = self.runtime, clock = self.clock, limit = loadTimeout
        let raw = Task { try await runtime.load(modelAt: path) }
        let model: any LoadedModel
        do {
            model = try await BuiltInWatchdog.race(raw, seconds: limit, clock: clock)
        } catch BuiltInError.loadTimedOut(let s) {
            gaveUp(on: raw, attempt: attempt, seconds: s)
            throw BuiltInError.loadTimedOut(seconds: s)
        }
        if let current = loaded {
            // Nothing else publishes while this load is `loading`; if a
            // model is here anyway, never drop one without unloading it.
            if current.path == path { model.unload(); return current.model }
            drop(current)
        }
        loaded = (path, model)
        loadCount += 1
        session.markLoaded()
        return model
    }

    private func drop(_ old: (path: URL, model: any LoadedModel)) {
        loaded = nil
        unloadCount += 1
        session.markUnloaded()
        old.model.unload()
    }

    private func admit(_ intent: BuiltInLoadIntent) throws {
        // Only reached when the model isn't in memory (`model(at:)`
        // returned it otherwise): an automatic caller never loads.
        if intent == .automatic {
            refusedAutomatic += 1
            throw session.unhealthy != nil || stuck != nil ? BuiltInError.unhealthy : BuiltInError.automaticLoadNotAllowed
        }
        // No second load while the stuck one runs; the retry is kept.
        if stuck != nil { throw BuiltInError.stillLoading }
        if session.unhealthy != nil {
            // Joining a retry already under way doesn't use another one.
            if loading != nil { return }
            guard session.takeRetry() else { throw BuiltInError.unhealthy }
        }
    }

    /// The watchdog fired. What can be stopped is asked to stop:
    /// cancelling `raw` makes `LlamaRuntime.load` return false from
    /// llama.cpp's progress callback (the file read stops at the next
    /// tensor) and set the context's abort flag (the warm-up decode stops
    /// between graph nodes where the backend checks it). What can't:
    /// `llama_init_from_model` (Metal buffers, no callback) and a GPU
    /// command buffer already submitted. Those are left to finish on
    /// llama.cpp's queue; nothing waits for them, and no other load starts
    /// until they do. A model that loads after all is freed, not used.
    private func gaveUp(on raw: Task<any LoadedModel, Error>, attempt: Int, seconds: Int) {
        session.markUnhealthy(seconds: seconds)
        AILog.logger.error("owl-ai builtin load watchdog fired after \(seconds)s; automatic AI off for this session")
        raw.cancel()
        stuck = (attempt, raw)
        Task { [weak self] in
            let r = await raw.result
            await self?.stuckFinished(r, attempt: attempt)
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .cedricBuiltInModelUnhealthy, object: nil, userInfo: ["seconds": seconds])
        }
    }

    /// Attempt `attempt`'s stuck load returned. Clears the record only if
    /// it is still that attempt's.
    private func stuckFinished(_ r: Result<any LoadedModel, Error>, attempt: Int) {
        if case .success(let m) = r { m.unload(); unloadCount += 1 }
        if stuck?.attempt == attempt { stuck = nil }
    }

    /// Frees the model now (Settings "Unload", a model deleted, idle).
    public func unload() {
        guard let old = loaded else { return }
        drop(old)
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        guard loaded != nil || active > 0 else { return }
        let wait = max(0, idleTimeout - (clock.now - lastUse))
        let clock = self.clock
        idleTimer = Task { [weak self] in
            do { try await clock.sleep(seconds: wait) } catch { return }
            await self?.idleCheck()
        }
    }

    /// Unloads when idle long enough; otherwise re-arms. Tests call it too.
    @discardableResult
    public func idleCheck() -> Bool {
        guard loaded != nil, active == 0 else { return false }
        if clock.now - lastUse >= idleTimeout {
            unload()
            return true
        }
        armIdleTimer()
        return false
    }
}

#if DEBUG
/// CEDRIC_BUILTIN_SPY=1 (debug builds): counts loads and answers every
/// request with no hints, without llama.cpp, Metal or the model file.
public final class SpyBuiltInRuntime: BuiltInRuntime, @unchecked Sendable {
    public static let shared = SpyBuiltInRuntime()
    private let lock = NSLock()
    private var _loads = 0
    private var _requests = 0
    public var loads: Int { lock.withLock { _loads } }
    public var requests: Int { lock.withLock { _requests } }

    public func load(modelAt url: URL) async throws -> any LoadedModel {
        lock.withLock { _loads += 1 }
        return Model(spy: self)
    }

    final class Model: LoadedModel, @unchecked Sendable {
        let spy: SpyBuiltInRuntime
        init(spy: SpyBuiltInRuntime) { self.spy = spy }
        func generate(_ request: GenerationRequest) async throws -> GenerationResult {
            spy.lock.withLock { spy._requests += 1 }
            return GenerationResult(text: #"{"hints":[]}"#)
        }
        func unload() {}
    }
}
#endif
