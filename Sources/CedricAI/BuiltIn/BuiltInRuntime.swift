import Foundation

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

#if !CEDRIC_BUILTIN
/// iOS: the pinned llama.cpp XCFramework has an iOS device slice but no
/// iOS Simulator slice, and SwiftPM can't tell the two apart, so CedricAI
/// doesn't link it on iOS. The iOS app compiles LlamaRuntime.swift and
/// CLlamaLoader.c itself for device builds only and sets `runtime` at
/// launch, before anything touches `BuiltInModelHost.shared`.
public enum BuiltInPlatform {
    nonisolated(unsafe) public static var runtime: (any BuiltInRuntime)?
    /// Shown where the built-in engine would be, when `runtime` is nil.
    public static let unavailableReason = "Built-in model: needs a real device."
}

/// Every load fails with a clear reason (the iOS Simulator).
public struct NoBuiltInRuntime: BuiltInRuntime {
    public init() {}
    public func load(modelAt url: URL) async throws -> any LoadedModel {
        throw BuiltInError.loadFailed(BuiltInPlatform.unavailableReason)
    }
}
#endif

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
public actor BuiltInModelHost {
    public static let defaultIdleTimeout: TimeInterval = 300

    /// The app's one host, so every provider shares the loaded model.
    #if CEDRIC_BUILTIN
    public static let shared = BuiltInModelHost(runtime: LlamaRuntime())
    #else
    public static let shared = BuiltInModelHost(runtime: BuiltInPlatform.runtime ?? NoBuiltInRuntime())
    #endif

    let runtime: any BuiltInRuntime
    let clock: any OwlClock
    public private(set) var idleTimeout: TimeInterval

    private var loaded: (path: URL, model: any LoadedModel)?
    private var loading: (path: URL, task: Task<any LoadedModel, Error>)?
    private var active = 0
    private var lastUse: TimeInterval = 0
    private var idleTimer: Task<Void, Never>?
    /// For tests and the log.
    public private(set) var loadCount = 0
    public private(set) var unloadCount = 0

    public init(runtime: any BuiltInRuntime, clock: any OwlClock = SystemClock(),
                idleTimeout: TimeInterval = BuiltInModelHost.defaultIdleTimeout) {
        self.runtime = runtime
        self.clock = clock
        self.idleTimeout = idleTimeout
    }

    public var loadedPath: URL? { loaded?.path }

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

    /// Loads (or reuses) the model at `path`, dropping any other one.
    public func model(at path: URL) async throws -> any LoadedModel {
        if let loaded, loaded.path == path { return loaded.model }
        if let loading, loading.path == path { return try await loading.task.value }
        if let old = loaded {
            loaded = nil
            unloadCount += 1
            old.model.unload()
        }
        let runtime = self.runtime
        let task = Task { try await runtime.load(modelAt: path) }
        loading = (path, task)
        defer { if loading?.path == path { loading = nil } }
        let model = try await task.value
        if let current = loaded, current.path == path { model.unload(); return current.model }
        loaded = (path, model)
        loadCount += 1
        return model
    }

    /// Frees the model now (Settings "Unload", a model deleted, idle).
    public func unload() {
        guard let old = loaded else { return }
        loaded = nil
        unloadCount += 1
        old.model.unload()
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

/// iOS kills an app (jetsam) that goes past its memory limit, which is far
/// below the device's RAM. Before loading a model the iOS app asks how much
/// it may still use (`os_proc_available_memory`) and refuses with a clear
/// message rather than getting killed mid-load.
public enum ModelMemoryGate {
    /// Weights, plus KV/compute buffers estimated for a 4K context (at least
    /// 400 MB), scaled with contextTokens, plus 256 MB slack.
    public static func bytesNeeded(forModelOfSize size: Int64, contextTokens: Int32 = 4096) -> Int64 {
        let contextScale = Int64(contextTokens) / 4096
        return size + max(400 * 1_048_576, size / 4) * contextScale + 256 * 1_048_576
    }

    /// Nil when `available` bytes are enough for `model`, else why not.
    public static func refusal(for model: BuiltInModel, available: Int64, contextTokens: Int32 = 4096) -> String? {
        let need = bytesNeeded(forModelOfSize: model.sizeBytes, contextTokens: contextTokens)
        guard available < need else { return nil }
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        return "Not enough memory for \(model.name): it needs about \(gb(need)) and Owlink can use \(gb(max(0, available))) right now. Close other apps or pick a smaller model."
    }
}
