import Foundation

/// One model as the server lists it, enriched where the backend says more.
public struct LocalModelInfo: Sendable, Equatable {
    public var id: String
    /// Bytes on disk, when the backend reports it (Ollama `/api/tags`).
    public var sizeBytes: Int64?
    /// Parameter count in billions: from the backend if it says, else parsed
    /// from the id ("qwen2.5-coder-1.5b-instruct" → 1.5).
    public var parametersB: Double?
    public var quantization: String?
    /// LM Studio `type`: "llm", "vlm", "embeddings".
    public var type: String?
    /// LM Studio `state`: "loaded" / "not-loaded".
    public var state: String?

    public init(id: String, sizeBytes: Int64? = nil, parametersB: Double? = nil,
                quantization: String? = nil, type: String? = nil, state: String? = nil) {
        self.id = id
        self.sizeBytes = sizeBytes
        self.parametersB = parametersB ?? ModelPicker.parameterCount(fromID: id)
        self.quantization = quantization
        self.type = type
        self.state = state
    }

    /// "1.5B · 4bit · 0.9 GB" — whatever is known.
    public var sizeLabel: String {
        var bits: [String] = []
        if let p = parametersB { bits.append(p < 10 ? String(format: "%.1fB", p) : String(format: "%.0fB", p)) }
        if let q = quantization { bits.append(q) }
        if let s = sizeBytes { bits.append(String(format: "%.1f GB", Double(s) / 1_000_000_000)) }
        return bits.joined(separator: " · ")
    }

    public var isEmbedding: Bool {
        type == "embeddings" || id.lowercased().contains("embed")
    }
}

public enum LocalAIError: Error, Sendable, Equatable {
    case endpointNotLocal(String)
    case http(Int)
    case badResponse
    case timedOut
    case cancelled
    case transport(String)
}

public struct ChatMessage: Sendable, Equatable, Encodable {
    public var role: String
    public var content: String
    public init(role: String, content: String) { self.role = role; self.content = content }
}

public struct ChatResult: Sendable, Equatable {
    public var content: String
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var latency: TimeInterval
}

public struct ConnectionReport: Sendable {
    public var models: [LocalModelInfo]
    public var latency: TimeInterval
    public var suggested: LocalModelInfo?
    public var error: LocalAIError?
}

/// A minimal OpenAI-compatible client (chat completions + model list) for
/// LM Studio and Ollama. URLSession only. Refuses non-local endpoints.
public struct LocalModelClient: Sendable {
    public let baseURL: URL
    let session: URLSession
    let timeout: TimeInterval
    /// Name lookup for `checkLocal`; tests put a slow one in.
    var resolver: @Sendable (String) async -> [String] = { await LocalEndpointPolicy.resolve($0) }

    /// Streams only: after the first byte of the answer, the longest wait
    /// for the next one.
    public var streamIdleLimit: TimeInterval = 30
    /// Streams only: a safety cap on one whole answer.
    public var streamCap: TimeInterval = 15 * 60
    /// Streams only: the clock the first-byte, idle and cap deadlines are
    /// measured on (monotonic seconds). Tests put a virtual one in, so a
    /// stalled CI runner can't make a dribble look like a stall.
    var streamClock: @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Streams only, tests only (nil in the app): told after each touch of
    /// the watch has been stored, with the time stored and the bytes read
    /// so far, so a virtual-time stub moves on only once the client has
    /// both read a chunk and reset its idle deadline on it.
    var streamTouched: (@Sendable (_ at: TimeInterval, _ bytesRead: Int) -> Void)? = nil
    /// `withDeadline`'s wait for `timeout` seconds. Tests whose point isn't
    /// the deadline put in one that never ends on its own, so a stalled CI
    /// runner can't make an answer in time look late.
    var deadlineSleep: @Sendable (TimeInterval) async throws -> Void = {
        try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1_000_000_000))
    }
    /// What every request gives URLSession as its own timeout (the wait
    /// between packets); nil: each request's usual one (`timeout`, or 2 s
    /// for `enrich`'s best-effort lookups). Tests that take the overall
    /// deadline off the wall clock take this one off too.
    var requestTimeout: TimeInterval? = nil

    public init(baseURL: URL, timeout: TimeInterval = 20, session: URLSession? = nil) {
        self.baseURL = baseURL
        self.timeout = timeout
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral   // no cookies, no cache on disk
            cfg.timeoutIntervalForRequest = timeout
            // A streamed answer may run long; every request has its own
            // deadline (`withDeadline`, or the stream's watch) inside this.
            cfg.timeoutIntervalForResource = max(timeout, 15 * 60)
            cfg.connectionProxyDictionary = [:]           // never route through a proxy
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    /// The server root without the trailing `/v1`, for backend-native
    /// endpoints (LM Studio `/api/v0/models`, Ollama `/api/tags`).
    var serverRoot: URL {
        baseURL.lastPathComponent == "v1" ? baseURL.deletingLastPathComponent() : baseURL
    }

    /// The name must pass the policy and, unless it is an address, every
    /// address it resolves to must be private (a `.local`, bare or
    /// `.ts.net` name can resolve to a public host). Returns the address
    /// the request must then go to (`Pin`): the connection uses the checked
    /// address itself, not a second lookup that a DNS server could answer
    /// differently (rebinding).
    @discardableResult
    func checkLocal() async throws -> Pin {
        guard LocalEndpointPolicy.isAllowed(baseURL) else {
            throw LocalAIError.endpointNotLocal(baseURL.host ?? baseURL.absoluteString)
        }
        guard let host = baseURL.host else { throw LocalAIError.endpointNotLocal(baseURL.absoluteString) }
        // getaddrinfo can't be cancelled: when the deadline passes, the
        // lookup is left to finish on its own and its answer is dropped.
        let resolver = self.resolver
        let addrs = try await Self.abandoningOnCancel { await resolver(host) }
        guard !addrs.isEmpty, addrs.allSatisfy(LocalEndpointPolicy.isPrivateAddress) else {
            throw LocalAIError.endpointNotLocal(host)
        }
        return Pin(host: host, addresses: addrs)
    }

    /// Where a request goes once `checkLocal` has passed: for a plain-http
    /// server named by a host name, the checked address, with the name
    /// kept in the `Host` header (so Ollama's and LM Studio's host checks
    /// and virtual hosts still see it). An address in the URL stays as it
    /// is, and so does https: URLSession sends the URL's host as the TLS
    /// server name (SNI) and has no way to connect to one address while
    /// naming another, and LAN servers behind Caddy or `tailscale serve`
    /// pick their certificate by that name. For https the certificate,
    /// which must match the name, and the peer check after the request
    /// (`RedirectGuard.checkPeers`) stand in for the pin.
    struct Pin: Sendable, Equatable {
        /// The address to connect to; nil: the URL is left alone. An IPv6
        /// link-local one carries its zone ("fe80::1%en0").
        let address: String?

        init(host: String, addresses: [String]) {
            let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            if LocalEndpointPolicy.isAddress(bare) {
                address = nil
            } else {
                // IPv4 first, then IPv6; a link-local IPv6 one only with
                // the zone (interface) the lookup gave, which it needs.
                let usable = addresses.filter { LocalEndpointPolicy.isAddress($0) }
                address = usable.first { !$0.contains(":") }
                    ?? usable.first { $0.contains(":") && !LocalEndpointPolicy.isLinkLocalV6($0) }
                    ?? usable.first { LocalEndpointPolicy.isLinkLocalV6($0) && $0.contains("%") }
            }
        }

        static func isAddress(_ s: String) -> Bool { LocalEndpointPolicy.isAddress(s) }

        /// The address as a URL host: IPv6 bracketed, a zone as "%25"
        /// (RFC 6874), so "fe80::1%en0" → "[fe80::1%25en0]".
        static func urlHost(_ address: String) -> String? {
            guard let (addr, zone) = LocalEndpointPolicy.splitZone(address) else { return nil }
            guard addr.contains(":") else { return zone == nil ? addr : nil }
            return "[" + addr + (zone.map { "%25" + $0 } ?? "") + "]"
        }

        func apply(_ request: URLRequest) -> URLRequest {
            guard let address, let url = request.url, url.scheme?.lowercased() == "http", let host = url.host,
                  let urlHost = Self.urlHost(address),
                  var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return request }
            c.percentEncodedHost = urlHost
            guard let pinned = c.url else { return request }
            var r = request
            r.url = pinned
            r.setValue(url.port.map { "\(host):\($0)" } ?? host, forHTTPHeaderField: "Host")
            return r
        }
    }

    /// Runs `work` under one overall deadline of `timeout` seconds: the name
    /// check, the request and reading the whole body. URLRequest's
    /// `timeoutInterval` only limits the wait between packets and doesn't
    /// cover the lookup; this does. At the deadline the work is cancelled
    /// (which cancels its URLSession task) and `.timedOut` is thrown.
    func withDeadline<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        let seconds = timeout, sleep = deadlineSleep
        do {
            return try await withThrowingTaskGroup(of: T?.self) { group in
                group.addTask { try await work() }
                group.addTask {
                    try await sleep(seconds)
                    return nil
                }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let value = first else { throw LocalAIError.timedOut }
                return value
            }
        } catch is CancellationError {
            throw LocalAIError.cancelled
        }
    }

    /// Awaits `op`, but returns (throwing CancellationError) as soon as the
    /// calling task is cancelled, without waiting for `op` to finish.
    static func abandoningOnCancel<T: Sendable>(_ op: @escaping @Sendable () async -> T) async throws -> T {
        let state = Locked<(c: CheckedContinuation<T, Error>?, done: Bool)>((nil, false))
        @Sendable func finish(_ r: Result<T, Error>) {
            let c: CheckedContinuation<T, Error>? = state.mutate { s in
                guard !s.done, let c = s.c else { return nil }
                s.done = true
                return c
            }
            c?.resume(with: r)
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                state.mutate { $0.c = c }
                if Task.isCancelled { finish(.failure(CancellationError())); return }
                Task.detached { finish(.success(await op())) }
            }
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// The most a response may be (a chat reply or a model list is far less).
    public static let maxResponseBytes = 2 * 1024 * 1024

    /// Redirects only to the same host (and only one the policy allows), so
    /// a "local" server can't forward the document text anywhere else; and
    /// where the request's connections actually went, from URLSession's
    /// metrics, for `checkPeers`.
    final class RedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
        /// The connections' peer addresses, once URLSession has reported them.
        private let peers = Locked<[String]?>(nil)

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            guard let from = task.originalRequest?.url, let to = request.url,
                  LocalEndpointPolicy.allowsRedirect(from: from, to: to) else { return nil }
            return request
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            record(metrics.transactionMetrics.compactMap(\.remoteAddress))
        }

        func record(_ addresses: [String]) { peers.mutate { $0 = addresses } }

        /// What URLSession reported (nil: nothing yet).
        var connectedAddresses: [String]? { peers.mutate { $0 } }

        /// After the response: every address the request connected to must
        /// be private, else `.endpointNotLocal`. This catches what the name
        /// check before the request can't for https (not pinned, so the
        /// connection does its own lookup): a DNS answer that changed to a
        /// public address in between. The request has been sent by then;
        /// the answer is dropped and the error shown. URLSession reports the
        /// addresses with the last bytes or a moment later: waits up to
        /// `wait` seconds for them, and passes when it hasn't (no
        /// connection was made, or a test's stub protocol).
        /// The wait is measured on `clock`, not counted in polls: a poll
        /// that oversleeps (a busy machine) doesn't stretch it.
        func checkPeers(wait: TimeInterval = 1, clock: any OwlClock = SystemClock()) async throws {
            let deadline = clock.now + wait
            var seen = peers.mutate { $0 }
            while seen == nil, clock.now < deadline, !Task.isCancelled {
                try? await clock.sleep(seconds: min(0.01, max(0, deadline - clock.now)))
                seen = peers.mutate { $0 }
            }
            if let bad = seen?.first(where: { !LocalEndpointPolicy.isPrivateAddress($0) }) {
                throw LocalAIError.endpointNotLocal(bad)
            }
        }
    }

    /// GET or POST with the redirect guard and the size cap.
    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let guardian = RedirectGuard()
        let (bytes, response) = try await session.bytes(for: request, delegate: guardian)
        if response.expectedContentLength > Int64(Self.maxResponseBytes) {
            bytes.task.cancel()
            throw LocalAIError.transport("response too large")
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            bytes.task.cancel()
            return (Data(), response)
        }
        var data = Data()
        for try await b in bytes {
            data.append(b)
            if data.count > Self.maxResponseBytes {
                bytes.task.cancel()
                throw LocalAIError.transport("response too large")
            }
        }
        try await guardian.checkPeers()
        return (data, response)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var request = request
        request.timeoutInterval = requestTimeout ?? timeout
        do {
            let (data, response) = try await fetch(request)
            guard let http = response as? HTTPURLResponse else { throw LocalAIError.badResponse }
            guard (200..<300).contains(http.statusCode) else { throw LocalAIError.http(http.statusCode) }
            return data
        } catch let e as LocalAIError {
            throw e
        } catch is CancellationError {
            throw LocalAIError.cancelled
        } catch let e as URLError {
            switch e.code {
            case .cancelled: throw LocalAIError.cancelled
            case .timedOut: throw LocalAIError.timedOut
            default: throw LocalAIError.transport(e.localizedDescription)
            }
        }
    }

    // MARK: Discovery

    public func listModels() async throws -> [LocalModelInfo] {
        try await withDeadline {
            let pin = try await checkLocal()
            let data = try await send(pin.apply(URLRequest(url: baseURL.appendingPathComponent("models"))))
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = obj["data"] as? [[String: Any]] else { throw LocalAIError.badResponse }
            var models = list.compactMap { ($0["id"] as? String).map { LocalModelInfo(id: $0) } }
            await enrich(&models, pin: pin)
            return models
        }
    }

    /// Best effort, short timeout: LM Studio's native list adds type,
    /// quantization and load state; Ollama's adds bytes and parameter size.
    private func enrich(_ models: inout [LocalModelInfo], pin: Pin) async {
        var quick = pin.apply(URLRequest(url: serverRoot.appendingPathComponent("api/v0/models")))
        quick.timeoutInterval = requestTimeout ?? 2
        if let data = try? await fetch(quick).0,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = obj["data"] as? [[String: Any]] {
            for entry in list {
                guard let id = entry["id"] as? String, let i = models.firstIndex(where: { $0.id == id }) else { continue }
                models[i].type = entry["type"] as? String
                models[i].quantization = entry["quantization"] as? String
                models[i].state = entry["state"] as? String
            }
            return
        }
        var tags = pin.apply(URLRequest(url: serverRoot.appendingPathComponent("api/tags")))
        tags.timeoutInterval = requestTimeout ?? 2
        if let data = try? await fetch(tags).0,
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let list = obj["models"] as? [[String: Any]] {
            for entry in list {
                guard let id = (entry["model"] as? String) ?? (entry["name"] as? String),
                      let i = models.firstIndex(where: { $0.id == id }) else { continue }
                if let size = entry["size"] as? NSNumber { models[i].sizeBytes = size.int64Value }
                if let details = entry["details"] as? [String: Any] {
                    if let q = details["quantization_level"] as? String { models[i].quantization = q }
                    if let p = details["parameter_size"] as? String,
                       let v = Double(p.trimmingCharacters(in: CharacterSet(charactersIn: "Bb "))) {
                        models[i].parametersB = v
                    }
                }
            }
        }
    }

    /// "Test connection": the model list, the round-trip latency and the
    /// small model the picker would choose.
    public func testConnection(clock: any OwlClock = SystemClock()) async -> ConnectionReport {
        let start = clock.now
        do {
            let models = try await listModels()
            return ConnectionReport(models: models, latency: clock.now - start,
                                    suggested: ModelPicker.pickSmallQwen(models), error: nil)
        } catch {
            return ConnectionReport(models: [], latency: clock.now - start, suggested: nil,
                                    error: (error as? LocalAIError) ?? .transport("\(error)"))
        }
    }

    // MARK: Chat

    /// One non-streaming chat completion. `jsonSchema`, when given, is sent
    /// as `response_format` (LM Studio and Ollama both honour json_schema);
    /// a 400 from a server that doesn't is retried once without it.
    public func chat(model: String, messages: [ChatMessage], maxTokens: Int,
                     temperature: Double = 0, jsonSchema: [String: Any]? = nil,
                     clock: any OwlClock = SystemClock()) async throws -> ChatResult {
        let withSchema = try chatRequest(model: model, messages: messages, maxTokens: maxTokens,
                                         temperature: temperature, jsonSchema: jsonSchema)
        let plain = jsonSchema == nil ? nil
            : try chatRequest(model: model, messages: messages, maxTokens: maxTokens, temperature: temperature, jsonSchema: nil)
        return try await withDeadline {
            let pin = try await checkLocal()
            let start = clock.now
            do {
                return try await chatOnce(pin.apply(withSchema), start: start, clock: clock)
            } catch LocalAIError.http(400) where plain != nil {
                return try await chatOnce(pin.apply(plain!), start: start, clock: clock)
            }
        }
    }

    private func chatRequest(model: String, messages: [ChatMessage], maxTokens: Int,
                             temperature: Double, jsonSchema: [String: Any]?) throws -> URLRequest {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false,
        ]
        if let jsonSchema {
            body["response_format"] = [
                "type": "json_schema",
                "json_schema": ["name": "owl_hints", "strict": true, "schema": jsonSchema],
            ]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func chatOnce(_ request: URLRequest, start: TimeInterval, clock: any OwlClock) async throws -> ChatResult {
        let data = try await send(request)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else { throw LocalAIError.badResponse }
        let usage = obj["usage"] as? [String: Any]
        return ChatResult(content: content,
                          promptTokens: (usage?["prompt_tokens"] as? NSNumber)?.intValue,
                          completionTokens: (usage?["completion_tokens"] as? NSNumber)?.intValue,
                          latency: clock.now - start)
    }
}

/// Chooses a small Qwen model automatically; never a large one, so a
/// default setup can't make LM Studio JIT-load a 35B model.
public enum ModelPicker {
    /// Billions of parameters from an id such as "qwen2.5-coder-1.5b-instruct",
    /// "qwen3:1.7b" or "Qwen3-4B-MLX-4bit". Ignores MoE active counts ("a3b")
    /// and quant suffixes ("4bit").
    public static func parameterCount(fromID id: String) -> Double? {
        let s = id.lowercased()
        let pattern = #"(?:^|[-_/:@\s])(\d+(?:\.\d+)?)b(?=$|[-_/:@.\s])"#
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return Double(s[r])
    }

    /// The automatic choice never goes above `maxAutoParametersB`, so a
    /// default setup can't make LM Studio JIT-load a big model:
    ///
    /// 1. a Qwen coder/instruct model of 2.5–4B (coder first, closest to 3B):
    ///    1.5B gives noticeably weaker hints;
    /// 2. else a Qwen of 1–2B (coder first, closest to 1.5B);
    /// 3. else a Qwen of 0.5–1B;
    /// 4. else nil: the user picks.
    public static func pickSmallQwen(_ models: [LocalModelInfo]) -> LocalModelInfo? {
        let candidates = models.filter {
            let id = $0.id.lowercased()
            return !$0.isEmbedding && id.contains("qwen")
                && (id.contains("coder") || id.contains("instruct") || id.contains("qwen3"))
        }
        let tiers: [(ClosedRange<Double>, Double)] = [(2.5...maxAutoParametersB, 3), (1...2, 1.5), (0.5...0.99, 0.5)]
        for (range, target) in tiers {
            let tier = candidates.filter { $0.parametersB.map(range.contains) ?? false }
            if let best = tier.min(by: { rank($0, target: target) < rank($1, target: target) }) { return best }
        }
        return nil
    }

    /// The largest model the automatic choice will take.
    public static let maxAutoParametersB = 4.0

    /// ≤ 2B: Settings › Cedric says "Small models give weaker hints."
    public static func isWeak(_ m: LocalModelInfo) -> Bool { (m.parametersB ?? 99) <= 2 }

    private static func rank(_ m: LocalModelInfo, target: Double) -> Double {
        let id = m.id.lowercased()
        let coderBonus = id.contains("coder") ? 0 : 10
        let instructBonus = id.contains("instruct") ? 0 : 0.01
        return Double(coderBonus) + abs((m.parametersB ?? 99) - target) + instructBonus
    }
}
