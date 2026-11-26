import Foundation

/// What an LM Studio or Ollama server says about a model's context window,
/// so a long prompt isn't cut off silently by a server running a small one
/// (both default to a 4096-token context). An OpenAI-compatible server
/// that says nothing keeps the 32 000-unit cap (`ContextWindow.serverBudget`).
public struct ServerContextReport: Sendable, Equatable {
    public enum Source: String, Sendable {
        /// The model is loaded with this context (LM Studio
        /// `loaded_context_length`, Ollama `/api/ps` `context_length`).
        case loaded
        /// Ollama: the model's `num_ctx` parameter (its Modelfile).
        case configured
        /// Not loaded: what the server loads it with by default (4096),
        /// never more than the model's own maximum.
        case serverDefault
    }

    public var tokens: Int
    public var source: Source

    public init(tokens: Int, source: Source) { self.tokens = tokens; self.source = source }

    /// LM Studio's and Ollama's default context for a model they load
    /// without a setting of their own.
    public static let defaultLoadTokens = 4_096

    /// Below this a number is not a context window (a parse slip): ignored.
    static let minimumTokens = 512

    /// At least `minimumTokens`; a larger number than any window
    /// (`ContextWindow.maximumWindowTokens`, up to Int.max from a server)
    /// counts as that, so nothing downstream does arithmetic on it.
    static func plausible(_ n: Int?) -> Int? {
        n.flatMap { $0 >= minimumTokens ? min($0, ContextWindow.maximumWindowTokens) : nil }
    }

    private static func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }

    private static func object(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Parsing (fixtures in tests; never throws)

    /// LM Studio `GET /api/v0/models`: the entry for `model`. Loaded:
    /// `loaded_context_length`; else the default load, capped by
    /// `max_context_length`. nil when the model isn't listed.
    public static func lmStudio(_ data: Data, model: String) -> ServerContextReport? {
        guard let list = object(data)?["data"] as? [[String: Any]],
              let entry = list.first(where: { ($0["id"] as? String) == model }) else { return nil }
        if (entry["state"] as? String) == "loaded", let n = plausible(int(entry["loaded_context_length"])) {
            return ServerContextReport(tokens: n, source: .loaded)
        }
        let maximum = plausible(int(entry["max_context_length"]))
        return ServerContextReport(tokens: min(defaultLoadTokens, maximum ?? .max), source: .serverDefault)
    }

    /// Ollama `GET /api/ps`: the loaded context of `model`, if it is loaded.
    public static func ollamaLoaded(_ data: Data, model: String) -> Int? {
        guard let list = object(data)?["models"] as? [[String: Any]] else { return nil }
        let entry = list.first { e in
            [e["model"], e["name"]].compactMap { $0 as? String }.contains { ollamaSameModel($0, model) }
        }
        return plausible(int(entry?["context_length"]))
    }

    /// Ollama `POST /api/show`: the Modelfile's `num_ctx` and the model's
    /// own maximum (`model_info["<arch>.context_length"]`). nil when the
    /// body isn't a show response.
    public static func ollamaShow(_ data: Data) -> (configured: Int?, maximum: Int?)? {
        guard let obj = object(data), obj["model_info"] != nil || obj["parameters"] != nil || obj["details"] != nil
        else { return nil }
        var configured: Int?
        for line in ((obj["parameters"] as? String) ?? "").split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace)
            if parts.count == 2, parts[0] == "num_ctx" { configured = plausible(Int(parts[1])) }
        }
        return (configured, modelMaximum(obj["model_info"] as? [String: Any] ?? [:]))
    }

    /// The model's own maximum from `model_info`: the key of its
    /// `general.architecture` (`qwen3` → `qwen3.context_length`) when that
    /// is plausible; else the smallest plausible `*.context_length` (a
    /// dictionary's order isn't stable, and the smaller cap never
    /// overflows the model). Implausible values are skipped, not fatal.
    static func modelMaximum(_ info: [String: Any]) -> Int? {
        if let arch = info["general.architecture"] as? String,
           let n = plausible(int(info[arch + ".context_length"])) { return n }
        return info.filter { $0.key.hasSuffix(".context_length") }.compactMap { plausible(int($0.value)) }.min()
    }

    /// Ollama's answer from `/api/ps` (loaded) and `/api/show`: loaded wins;
    /// else `num_ctx`; else Ollama's default load. Each capped by the
    /// model's maximum when known. nil when neither endpoint answered.
    public static func ollama(loaded: Int?, show: (configured: Int?, maximum: Int?)?) -> ServerContextReport? {
        if let loaded { return ServerContextReport(tokens: loaded, source: .loaded) }
        guard let show else { return nil }
        let cap = show.maximum ?? .max
        if let n = show.configured { return ServerContextReport(tokens: min(n, cap), source: .configured) }
        return ServerContextReport(tokens: min(defaultLoadTokens, cap), source: .serverDefault)
    }

    /// "qwen3" and "qwen3:latest" are the same Ollama model.
    static func ollamaSameModel(_ a: String, _ b: String) -> Bool {
        func full(_ s: String) -> String { s.contains(":") ? s : s + ":latest" }
        return full(a) == full(b)
    }
}

extension LocalModelClient {
    /// Asks the server for `model`'s context window: LM Studio's native
    /// list, Ollama's `/api/ps` and `/api/show` (which one by `kind`; a
    /// custom server is tried as LM Studio, then Ollama). The same rules
    /// as every request (`checkLocal`, the redirect guard, the size cap),
    /// all under this client's one deadline. nil for anything else: a
    /// server that doesn't say, an error, a timeout. Never throws.
    public func contextReport(model: String, kind: LocalAISettings.Backend) async -> ServerContextReport? {
        try? await withDeadline {
            let pin = try await checkLocal()
            if kind != .ollama {
                let list = pin.apply(URLRequest(url: serverRoot.appendingPathComponent("api/v0/models")))
                if let data = try? await fetchOK(list), let r = ServerContextReport.lmStudio(data, model: model) { return r }
                if kind == .lmStudio { return nil }
            }
            let ps = pin.apply(URLRequest(url: serverRoot.appendingPathComponent("api/ps")))
            let loaded = (try? await fetchOK(ps)).flatMap { ServerContextReport.ollamaLoaded($0, model: model) }
            if let loaded { return ServerContextReport(tokens: loaded, source: .loaded) }
            var show = URLRequest(url: serverRoot.appendingPathComponent("api/show"))
            show.httpMethod = "POST"
            show.setValue("application/json", forHTTPHeaderField: "Content-Type")
            show.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "name": model])
            let shown = (try? await fetchOK(pin.apply(show))).flatMap(ServerContextReport.ollamaShow)
            return ServerContextReport.ollama(loaded: nil, show: shown)
        }
    }

    /// A 2xx body, else throws.
    private func fetchOK(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await fetch(request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw LocalAIError.badResponse
        }
        return data
    }
}

/// The context reports, per server and model, for a while: a loaded
/// model's for 5 minutes, a guess (not loaded yet) or no answer for 30 s,
/// so a model loaded later with another context is seen soon. Reading is a
/// lock, never a request: `current` starts a refresh in the background
/// when the entry is stale and returns what it has.
public final class ServerContextCache: @unchecked Sendable {
    public static let shared = ServerContextCache()

    static let loadedLifetime: TimeInterval = 300
    static let guessLifetime: TimeInterval = 30
    /// The probe's whole deadline (name check and every request).
    public static let probeTimeout: TimeInterval = 3

    private struct Entry { var report: ServerContextReport?; var at: TimeInterval }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var running: [String: Task<ServerContextReport?, Never>] = [:]
    private let now: @Sendable () -> TimeInterval
    private let probe: @Sendable (LocalModelClient, String, LocalAISettings.Backend) async -> ServerContextReport?
    /// How long `refresh` waits when not told (tests: long, so only the
    /// probe decides).
    private let defaultWait: TimeInterval

    init(now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         defaultWait: TimeInterval = probeTimeout,
         probe: @escaping @Sendable (LocalModelClient, String, LocalAISettings.Backend) async -> ServerContextReport? = {
             client, model, kind in
             let quick = LocalModelClient(baseURL: client.baseURL, timeout: ServerContextCache.probeTimeout, session: client.session)
             return await quick.contextReport(model: model, kind: kind)
         }) {
        self.now = now; self.probe = probe; self.defaultWait = defaultWait
    }

    static func key(_ client: LocalModelClient, _ model: String, _ kind: LocalAISettings.Backend) -> String {
        "\(kind.rawValue) \(client.baseURL.absoluteString) \(model)"
    }

    private func fresh(_ e: Entry) -> Bool {
        let life = e.report?.source == .loaded ? Self.loadedLifetime : Self.guessLifetime
        return now() - e.at < life
    }

    /// What is known now (nil: nothing yet, or the server doesn't say);
    /// refreshes in the background when stale.
    public func current(client: LocalModelClient, model: String, kind: LocalAISettings.Backend) -> ServerContextReport? {
        lookup(Self.key(client, model, kind), client, model, kind).entry?.report
    }

    /// Waits up to `wait` seconds (default `probeTimeout`) for a fresh
    /// report (the engine being made, before the first question); a probe
    /// still running after that finishes in the background.
    public func refresh(client: LocalModelClient, model: String, kind: LocalAISettings.Backend,
                        wait: TimeInterval? = nil) async -> ServerContextReport? {
        let found = lookup(Self.key(client, model, kind), client, model, kind)
        guard let task = found.probe else { return found.entry?.report }
        // The deadline counts from this call, not from when the timer task
        // first runs, so a busy pool can't stretch the wait.
        let deadline = ContinuousClock.now + .seconds(max(0, wait ?? defaultWait))
        // Whichever ends first: the probe, or the wait (nil; the probe
        // goes on and stores its answer for the next read). Not a task
        // group: leaving one waits for every child, the probe included.
        let pending = Locked<CheckedContinuation<ServerContextReport?, Never>?>(nil)
        @Sendable func finish(_ r: ServerContextReport?) {
            pending.mutate { c in defer { c = nil }; return c }?.resume(returning: r)
        }
        return await withCheckedContinuation { (c: CheckedContinuation<ServerContextReport?, Never>) in
            pending.mutate { $0 = c }
            let timer = Task {
                try? await Task.sleep(until: deadline, clock: .continuous)
                if !Task.isCancelled { finish(nil) }
            }
            Task {
                let report = await task.value
                // An answer after the deadline is late even when the timer
                // hasn't run yet: nil, as the wait promised (it is stored).
                finish(ContinuousClock.now < deadline ? report : nil)
                timer.cancel()
            }
        }
    }

    /// The entry, and the probe to wait for when it isn't fresh (the one
    /// running, or a new one), in one hold of the lock: checked apart, a
    /// probe ending between the check and the start would be asked again.
    private func lookup(_ key: String, _ client: LocalModelClient, _ model: String,
                        _ kind: LocalAISettings.Backend) -> (entry: Entry?, probe: Task<ServerContextReport?, Never>?) {
        lock.withLock {
            let entry = entries[key]
            if let entry, fresh(entry) { return (entry, nil) }
            if let t = running[key] { return (entry, t) }
            let probe = self.probe
            let t = Task.detached(priority: .utility) { [weak self] () -> ServerContextReport? in
                let report = await probe(client, model, kind)
                self?.store(key, report)
                return report
            }
            running[key] = t
            return (entry, t)
        }
    }

    private func store(_ key: String, _ report: ServerContextReport?) {
        let previous: ServerContextReport?? = lock.withLock {
            let old = entries[key].map(\.report)
            entries[key] = Entry(report: report, at: now())
            running[key] = nil
            return old
        }
        guard previous != .some(report), let report else { return }
        let budget = ContextWindow.serverBudget(contextTokens: report.tokens)
        let source = report.source.rawValue
        ContextWindow.logger.info(
            "server context \(report.tokens, privacy: .public) tokens (\(source, privacy: .public)): budget \(budget, privacy: .public) units")
    }
}
