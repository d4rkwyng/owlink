import Foundation
import llama
import CLlamaLoader

/// The real runtime: llama.cpp (the pinned XCFramework, MIT) running a GGUF
/// model in-process. Apple silicon offloads every layer to Metal; Intel
/// Macs run on the CPU (ggml's Metal path on Intel GPUs is not something we
/// test or rely on), which works but is slow.
public struct LlamaRuntime: BuiltInRuntime {
    /// n_ctx for a model that isn't in the catalog (live tests only):
    /// the largest step. Catalog models use `BuiltInModel.contextTokens()`,
    /// which `BuiltInChatEngine.contextBudget` reads too.
    static let uncatalogedContextTokens = ContextWindow.builtInSteps[0]
    static let batchTokens: Int32 = 512

    public init() {}

    /// True on Intel: the built-in engine runs on the CPU there.
    public static var isSlowHardware: Bool {
        #if arch(x86_64)
        return true
        #else
        return false
        #endif
    }

    /// llama.cpp, loaded on the first model load (not linked: see
    /// CLlamaLoader.h), with its backend initialised.
    nonisolated(unsafe) private static let api: Result<cedric_llama_api, BuiltInError> = {
        var err = [CChar](repeating: 0, count: 512)
        guard let p = cedric_llama_load(&err, err.count) else { return .failure(.loadFailed(String(cString: err))) }
        let L = p.pointee
        L.llama_log_set!({ _, _, _ in }, nil)   // llama.cpp is chatty on stderr; keep it quiet
        L.llama_backend_init!()
        return .success(L)
    }()

    /// A GGUF loaded without the catalog check: live tests only (a model
    /// that isn't in Owlink's list, such as a hybrid one for the KV-cache
    /// fallback). Never called by the app.
    static func loadForTesting(path: String) throws -> LlamaModel {
        let model = try LlamaModel(path: path, api: api.get(), contextTokens: uncatalogedContextTokens)
        LlamaModel.registerForExit(model)
        return model
    }

    /// Loads llama.cpp now (it is not linked); nil if it works, else why
    /// not. For Scripts/launch-check.sh (the bundled framework must load).
    public static func loadCheck() -> String? {
        if case .failure(let e) = api { return "\(e)" }
        return nil
    }

    public func load(modelAt url: URL) async throws -> any LoadedModel {
        guard FileManager.default.fileExists(atPath: url.path) else { throw BuiltInError.notInstalled }
        // Only a catalog model whose bytes are still the catalog's
        // (ModelStore.verifiedForLoad; hashed again after any change).
        guard let model = ModelCatalog.bundled()?.models.first(where: { $0.fileName == url.lastPathComponent }) else {
            throw BuiltInError.loadFailed("not a model from Owlink's list")
        }
        let store = ModelStore(directory: url.deletingLastPathComponent())
        // Gated on this Mac's memory and the model's size (16 384, 8192 or 4096).
        let contextTokens = model.contextTokens()
        // Off the main thread, on llama.cpp's queue. Cancelling (the
        // host's watchdog, BuiltInWatchdog) sets `stop`: the file read
        // stops at its next progress callback and the warm-up decode at
        // its next abort check. llama_init_from_model has no callback and
        // can't be stopped; a model that finishes anyway is freed here.
        let stop = LlamaLoadStop()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                LlamaModel.queue.async {
                    guard !stop.isSet else { cont.resume(throwing: BuiltInError.cancelled); return }
                    guard store.verifiedForLoad(model) else {
                        cont.resume(throwing: BuiltInError.loadFailed("the model file doesn't match its checksum; delete it and download it again"))
                        return
                    }
                    do {
                        let model = try LlamaModel(path: url.path, api: Self.api.get(), contextTokens: contextTokens, stop: stop)
                        LlamaModel.registerForExit(model)
                        do {
                            // The first decode, inside the watchdog's time.
                            try model.warmUp()
                        } catch {
                            model.freeNow()
                            throw stop.isSet ? BuiltInError.cancelled : error
                        }
                        if stop.isSet { model.freeNow(); throw BuiltInError.cancelled }
                        cont.resume(returning: model)
                    } catch { cont.resume(throwing: stop.isSet ? BuiltInError.cancelled : error) }
                }
            }
        } onCancel: {
            stop.set()
        }
    }
}

/// Set when a load is given up on. llama.cpp polls it from its loader
/// thread (progress callback) and from graph compute (abort callback).
/// The abort callback also asks the request running now (`current`):
/// a cancelled question stops its prefill or decode between graph nodes,
/// not only between batches.
final class LlamaLoadStop: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var current: LlamaRequestStop?
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
    /// The request whose cancel aborts a decode now (nil between requests).
    func begin(_ request: LlamaRequestStop?) { lock.withLock { current = request } }
    /// What the context's abort callback answers.
    var shouldAbort: Bool { lock.withLock { flag || (current?.isSet ?? false) } }
    var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
    static func from(_ p: UnsafeMutableRawPointer?) -> LlamaLoadStop? {
        p.map { Unmanaged<LlamaLoadStop>.fromOpaque($0).takeUnretainedValue() }
    }
}

/// One generate call's cancel. Each request has its own, so a new request
/// starting can never clear an older one's cancel (0.5.2 had one flag per
/// model, reset by every `generate`: a question cancelled while it waited
/// or prefilled ran on to its end once the next request, the owl's or the
/// user's, began, and the next question waited behind it).
final class LlamaRequestStop: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var isSet: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}

/// A loaded GGUF model plus one context. Every llama.cpp call happens on
/// `queue`, so the C state is never touched from two threads.
final class LlamaModel: LoadedModel, @unchecked Sendable {
    static let queue: DispatchQueue = {
        let q = DispatchQueue(label: "net.mindtricks.cedric.llama", qos: .userInitiated)
        q.setSpecific(key: queueKey, value: true)
        return q
    }()

    private var model: OpaquePointer?
    private var context: OpaquePointer?
    private let vocab: OpaquePointer?
    private let template: String?

    /// What the KV cache holds (sequence 0), token by token: the last
    /// request's prompt and the tokens decoded after it. nil when unknown
    /// (after an error or a cancel): the next request clears the cache.
    /// Only touched on `queue`.
    private var cached: [llama_token]? = []
    /// Requests whose cache couldn't be cut back (a hybrid or recurrent
    /// model: `llama_memory_seq_rm` refused) and were cleared instead.
    private(set) var cacheFallbacks = 0
    /// Off: clear the cache on every request, as 0.2 did (the live
    /// comparison in LiveKVCacheTests).
    nonisolated(unsafe) static var reuseKVCache = true

    /// llama.cpp's functions (CLlamaLoader).
    private let L: cedric_llama_api
    /// The context's n_ctx: the prompt plus the answer must fit.
    let contextTokens: Int
    /// The load's stop flag; llama.cpp holds a pointer to it (progress and
    /// abort callbacks), so it lives as long as the context.
    private let stop: LlamaLoadStop

    init(path: String, api: cedric_llama_api, contextTokens: Int, stop: LlamaLoadStop = LlamaLoadStop()) throws {
        L = api
        self.contextTokens = contextTokens
        self.stop = stop
        var mp = L.llama_model_default_params!()
        // Returning false stops the load (the watchdog gave up on it).
        mp.progress_callback = { _, data in !(LlamaLoadStop.from(data)?.isSet ?? false) }
        mp.progress_callback_user_data = stop.pointer
        #if arch(x86_64)
        mp.n_gpu_layers = 0
        #else
        mp.n_gpu_layers = 999
        #endif
        guard let m = L.llama_model_load_from_file!(path, mp) else {
            throw BuiltInError.loadFailed("llama.cpp could not read the model file")
        }
        var cp = L.llama_context_default_params!()
        cp.n_ctx = UInt32(contextTokens)
        cp.n_batch = UInt32(LlamaRuntime.batchTokens)
        // True aborts a decode: after the watchdog gave up on this load,
        // or (below) the running request was cancelled. Backends check it between graph nodes (best effort on
        // Metal: a command buffer already on the GPU runs to its end).
        // Also true once the running request is cancelled (Stop, a new
        // question, the panel closed): its prefill stops mid-batch.
        cp.abort_callback = { data in LlamaLoadStop.from(data)?.shouldAbort ?? false }
        cp.abort_callback_data = stop.pointer
        #if arch(x86_64)
        let threads = Int32(max(1, Self.physicalCores()))
        cp.n_threads = threads
        cp.n_threads_batch = threads
        #endif
        guard let c = L.llama_init_from_model!(m, cp) else {
            L.llama_model_free!(m)
            throw BuiltInError.loadFailed("llama.cpp could not create a context")
        }
        model = m
        context = c
        vocab = L.llama_model_get_vocab!(m)
        template = L.llama_model_chat_template!(m, nil).map { String(cString: $0) }
    }

    func unload() {
        Self.queue.async { [self] in freeOnQueue() }
    }

    /// Frees now; on `queue` only (a load that was given up on).
    func freeNow() { freeOnQueue() }

    /// One tiny decode right after the context is made: the first decode
    /// is where Metal builds its pipelines and first runs a graph, so a GPU
    /// that hangs, hangs here, inside the load and its watchdog, not in
    /// the user's first request. The cache is cleared afterwards. On `queue`.
    func warmUp() throws {
        guard let context else { throw BuiltInError.notInstalled }
        var tokens = Array(tokenize("ok").prefix(4))
        guard !tokens.isEmpty else { return }
        let rc = tokens.withUnsafeMutableBufferPointer { buf in
            L.llama_decode!(context, L.llama_batch_get_one!(buf.baseAddress!, Int32(buf.count)))
        }
        L.llama_memory_clear!(L.llama_get_memory!(context), true)
        cached = []
        guard rc == 0 else { throw BuiltInError.loadFailed("llama.cpp could not run the model (warm-up decode \(rc))") }
    }

    private func freeOnQueue() {
        if let context { L.llama_free!(context) }
        if let model { L.llama_model_free!(model) }
        context = nil
        model = nil
        Self.liveLock.withLock { Self.live[ObjectIdentifier(self)] = nil }
    }

    // MARK: Exit
    //
    // ggml's Metal device is a C++ static; if the process exits while a
    // context still holds Metal buffers, its destructor aborts (SIGABRT,
    // a crash report on every quit). So every model is freed first, from
    // an atexit handler registered after the device exists (atexit
    // handlers and C++ static destructors run in reverse order, so ours
    // runs before ggml's).

    nonisolated(unsafe) private static var live: [ObjectIdentifier: LlamaModel] = [:]
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var exitHookInstalled = false

    static func registerForExit(_ model: LlamaModel) {
        liveLock.withLock {
            live[ObjectIdentifier(model)] = model
            if !exitHookInstalled {
                exitHookInstalled = true
                atexit { LlamaModel.freeAllNow() }
            }
        }
    }

    /// How long exit waits for llama.cpp's queue to free the models. A
    /// request or warm-up stops at the abort flag (set first) within a
    /// graph node or a batch; only a decode the flag can't reach (a GPU
    /// that hung) or an unstoppable context creation takes longer.
    static let exitWait: TimeInterval = 5

    /// Frees every loaded model synchronously, at exit (the atexit hook).
    ///
    /// The model is registered before its warm-up decode, so a warm-up the
    /// watchdog gave up on (a GPU that hung, the abort flag never read) is
    /// in `live` while it blocks the queue. Waiting for the queue without
    /// a limit made Quit hang there (0.5.3). If the queue doesn't free them
    /// within `exitWait`, the process ends at once with `_exit`: freeing
    /// would wait forever, and running ggml's Metal device destructor with
    /// a context still alive aborts.
    static func freeAllNow() {
        let models = liveLock.withLock { Array(live.values) }
        guard !models.isEmpty else { return }
        for m in models { m.stop.set() }
        let free: @Sendable () -> Void = { for m in models { m.freeOnQueue() } }
        if DispatchQueue.getSpecific(key: queueKey) != nil { free(); return }
        if runBounded(on: queue, timeout: exitWait, free) { return }
        fflush(nil)
        _exit(0)
    }

    /// Runs `work` on `queue` and waits at most `timeout` seconds for it:
    /// true if it ran, false if the queue was still busy (`work` stays
    /// queued). Exit's wait (`freeAllNow`).
    static func runBounded(on queue: DispatchQueue, timeout: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { work(); done.signal() }
        return done.wait(timeout: .now() + timeout) == .success
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        try await generate(request, stream: nil)
    }

    func generate(_ request: GenerationRequest, onText: @escaping @Sendable (String) -> Void) async throws -> GenerationResult {
        try await generate(request, stream: onText)
    }

    private func generate(_ request: GenerationRequest, stream: (@Sendable (String) -> Void)?) async throws -> GenerationResult {
        // This request's own cancel: set by its task's cancellation, read
        // by `run` between tokens and batches and by llama.cpp's abort
        // callback inside a decode. Never cleared by a later request.
        let cancel = LlamaRequestStop()
        if Task.isCancelled { throw BuiltInError.cancelled }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                Self.queue.async { [self] in
                    // Cancelled while it waited for the queue: never starts.
                    guard !cancel.isSet else { cont.resume(throwing: BuiltInError.cancelled); return }
                    stop.begin(cancel)
                    defer { stop.begin(nil) }
                    do { cont.resume(returning: try run(request, cancel: cancel, stream: stream)) } catch {
                        // An aborted decode returns an error code: it is the cancel.
                        cont.resume(throwing: cancel.isSet ? BuiltInError.cancelled : error)
                    }
                }
            }
        } onCancel: {
            cancel.set()
        }
    }

    // MARK: On `queue`

    private func run(_ request: GenerationRequest, cancel: LlamaRequestStop,
                     stream: (@Sendable (String) -> Void)? = nil) throws -> GenerationResult {
        var isCancelled: Bool { cancel.isSet || stop.isSet }
        guard let context, let vocab else { throw BuiltInError.notInstalled }
        let prompt = formatChat(request.conversation)
        var tokens = tokenize(prompt)
        let limit = contextTokens - request.maxTokens
        guard tokens.count <= limit else { throw BuiltInError.promptTooLong(tokens: tokens.count, limit: limit) }

        let sampler = makeSampler(grammar: request.grammar)
        defer { L.llama_sampler_free!(sampler) }

        // Keep the prompt prefix the cache already holds (a tool round
        // repeats the system prompt, the document and earlier rounds) and
        // drop only what follows it.
        let mem = L.llama_get_memory!(context)
        let keep = prepareCache(mem, for: tokens)
        var record = Array(tokens.prefix(keep))
        cached = nil   // until this request finishes
        record.reserveCapacity(tokens.count + request.maxTokens)

        // Prefill in batches.
        let t0 = Date()
        var i = keep
        while i < tokens.count {
            if isCancelled { throw BuiltInError.cancelled }
            let n = min(Int(LlamaRuntime.batchTokens), tokens.count - i)
            let rc = tokens.withUnsafeMutableBufferPointer { buf in
                L.llama_decode!(context, L.llama_batch_get_one!(buf.baseAddress! + i, Int32(n)))
            }
            guard rc == 0 else { throw BuiltInError.generationFailed("decode \(rc)") }
            record.append(contentsOf: tokens[i..<(i + n)])
            i += n
        }
        let promptSeconds = Date().timeIntervalSince(t0)

        // Generate.
        let t1 = Date()
        var bytes: [UInt8] = []
        var generated = 0
        var piece = [CChar](repeating: 0, count: 256)
        var decoder = UTF8StreamDecoder()
        while generated < request.maxTokens {
            if isCancelled { throw BuiltInError.cancelled }
            var token = L.llama_sampler_sample!(sampler, context, -1)
            if L.llama_vocab_is_eog!(vocab, token) { break }
            let n = L.llama_token_to_piece!(vocab, token, &piece, Int32(piece.count), 0, false)
            if n > 0 {
                let new = piece[0..<Int(n)].map { UInt8(bitPattern: $0) }
                bytes.append(contentsOf: new)
                if let stream { let t = decoder.append(new); if !t.isEmpty { stream(t) } }
            }
            generated += 1
            let rc = L.llama_decode!(context, L.llama_batch_get_one!(&token, 1))
            guard rc == 0 else { throw BuiltInError.generationFailed("decode \(rc)") }
            record.append(token)
        }
        let promptCount = tokens.count
        tokens.removeAll()
        cached = record
        if let stream { let t = decoder.flush(); if !t.isEmpty { stream(t) } }
        return GenerationResult(text: String(decoding: bytes, as: UTF8.self),
                                promptTokens: promptCount, completionTokens: generated,
                                promptSeconds: promptSeconds, generateSeconds: Date().timeIntervalSince(t1),
                                reusedTokens: keep)
    }

    /// Readies the KV cache for `prompt`: keeps the longest prefix it
    /// already holds and removes the rest (`llama_memory_seq_rm`), or
    /// clears it all. Returns how many leading tokens were kept.
    ///
    /// A full clear when: reuse is off; the cache's state is unknown or
    /// its last position (`llama_memory_seq_pos_max`) is not the last
    /// token we recorded; nothing is shared; or the memory can't keep a
    /// partial prefix. Hybrid and recurrent models (Mamba, Gated DeltaNet
    /// layers) keep a state, not per-position entries:
    /// `llama_memory_seq_rm` returns false for a partial removal, and that
    /// return value is the test, so no list of architectures is needed.
    /// After a cut that succeeded, the first position
    /// (`llama_memory_seq_pos_min`) must still be 0: a sliding-window cache
    /// that dropped early positions, or a recurrent one whose only cell is
    /// the last position (a pure append, nothing to remove), is cleared too.
    private func prepareCache(_ mem: llama_memory_t?, for prompt: [llama_token]) -> Int {
        let plan = Self.cachePlan(cached: cached, prompt: prompt, reuse: Self.reuseKVCache,
                                  positions: { (Int(L.llama_memory_seq_pos_min!(mem, 0)), Int(L.llama_memory_seq_pos_max!(mem, 0))) },
                                  removeFrom: { L.llama_memory_seq_rm!(mem, 0, llama_pos($0), -1) })
        if plan.refused { cacheFallbacks += 1 }
        if plan.keep == 0 { L.llama_memory_clear!(mem, true) }
        return plan.keep
    }

    /// The decision behind `prepareCache`, without llama.cpp (unit-tested):
    /// how many tokens to keep, and whether the memory refused to cut.
    static func cachePlan<T: Equatable>(cached: [T]?, prompt: [T], reuse: Bool, positions: () -> (first: Int, last: Int),
                                        removeFrom: (Int) -> Bool) -> (keep: Int, refused: Bool) {
        guard reuse, let cached else { return (0, false) }
        let keep = reusablePrefix(cached: cached, prompt: prompt)
        guard keep > 0, positions().last == cached.count - 1 else { return (0, false) }
        guard removeFrom(keep), positions().first == 0 else { return (0, true) }
        return (keep, false)
    }

    /// How many leading tokens of `prompt` the cache can keep: the common
    /// prefix with what it holds, leaving at least one prompt token to
    /// decode (its logits pick the first new token). 0 when unknown.
    static func reusablePrefix<T: Equatable>(cached: [T]?, prompt: [T]) -> Int {
        guard let cached else { return 0 }
        let limit = min(cached.count, prompt.count - 1)
        var n = 0
        while n < limit, cached[n] == prompt[n] { n += 1 }
        return n
    }

    /// Forgets what the cache holds: the next request clears it.
    func invalidateCache() {
        Self.queue.sync { cached = nil }
    }

    /// llama.cpp parses `grammar` (live tests: a GBNF llama.cpp rejects
    /// would leave the output unconstrained, see `makeSampler`).
    func grammarCompiles(_ grammar: String) -> Bool {
        Self.queue.sync {
            guard let g = L.llama_sampler_init_grammar!(vocab, grammar, "root") else { return false }
            L.llama_sampler_free!(g)
            return true
        }
    }

    private func makeSampler(grammar: String?) -> UnsafeMutablePointer<llama_sampler> {
        let chain = L.llama_sampler_chain_init!(L.llama_sampler_chain_default_params!())!
        if let grammar, let g = L.llama_sampler_init_grammar!(vocab, grammar, "root") {
            L.llama_sampler_chain_add!(chain, g)
        }
        // Hints should be repeatable: greedy decoding.
        L.llama_sampler_chain_add!(chain, L.llama_sampler_init_greedy!())
        return chain
    }

    private func tokenize(_ text: String) -> [llama_token] {
        let len = Int32(text.utf8.count)
        var out = [llama_token](repeating: 0, count: Int(len) + 8)
        var n = L.llama_tokenize!(vocab, text, len, &out, Int32(out.count), true, true)
        if n < 0 {
            out = [llama_token](repeating: 0, count: Int(-n))
            n = L.llama_tokenize!(vocab, text, len, &out, Int32(out.count), true, true)
        }
        return Array(out.prefix(Int(max(0, n))))
    }

    /// The model's own chat template (llama.cpp knows ChatML, which every
    /// catalog model uses); plain ChatML if it can't be applied.
    private func formatChat(_ messages: [ChatMessage]) -> String {
        let chatML = messages.map { "<|im_start|>\($0.role)\n\($0.content)<|im_end|>\n" }.joined() + "<|im_start|>assistant\n"
        // C strings that live for the whole call.
        let roles = messages.map { strdup($0.role) }
        let contents = messages.map { strdup($0.content) }
        defer { roles.forEach { free($0) }; contents.forEach { free($0) } }
        var msgs = zip(roles, contents).map { llama_chat_message(role: $0, content: $1) }
        let total = messages.reduce(0) { $0 + $1.content.utf8.count }
        var buf = [CChar](repeating: 0, count: total * 2 + 512)
        var n = L.llama_chat_apply_template!(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        if n > Int32(buf.count) {
            buf = [CChar](repeating: 0, count: Int(n) + 1)
            n = L.llama_chat_apply_template!(template, &msgs, msgs.count, true, &buf, Int32(buf.count))
        }
        guard n > 0 else { return chatML }
        return String(decoding: buf[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func physicalCores() -> Int {
        var cores: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.physicalcpu", &cores, &size, nil, 0) == 0, cores > 0 { return Int(cores) }
        return ProcessInfo.processInfo.activeProcessorCount
    }
}
