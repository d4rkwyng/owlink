import Foundation
@testable import CedricAI
import CedricCore

// MARK: - URLProtocol stub server

/// A fake HTTP server. Each test registers handlers under its own port on
/// localhost, so parallel tests never see each other's routes.
final class StubServer: @unchecked Sendable {
    struct Response: Sendable {
        var status = 200
        var body: Data
        var delay: TimeInterval = 0
        /// Sent after `body`, one every `every` seconds (a slow stream).
        var chunks: [Data] = []
        var every: TimeInterval = 0
    }
    typealias Handler = @Sendable (URLRequest, Data?) -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [Int: StubServer] = [:]
    nonisolated(unsafe) private static var nextPort = 40_000

    let port: Int
    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private(set) var requests: [(path: String, body: Data?)] = []

    init() {
        port = Self.lock.withLock { Self.nextPort += 1; return Self.nextPort }
        Self.lock.withLock { Self.servers[port] = self }
    }

    var baseURL: URL { URL(string: "http://localhost:\(port)/v1")! }

    func route(_ path: String, _ handler: @escaping Handler) {
        lock.withLock { routes[path] = handler }
    }

    func json(_ path: String, _ object: Any, status: Int = 200, delay: TimeInterval = 0) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        route(path) { _, _ in Response(status: status, body: data, delay: delay) }
    }

    var session: URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }

    var recorded: [(path: String, body: Data?)] { lock.withLock { requests } }

    fileprivate static func server(for port: Int) -> StubServer? { lock.withLock { servers[port] } }

    fileprivate func handle(_ request: URLRequest, body: Data?) -> Response {
        let path = request.url?.path ?? ""
        let handler: Handler? = lock.withLock {
            requests.append((path, body))
            return routes[path]
        }
        return handler?(request, body) ?? Response(status: 404, body: Data())
    }
}

struct UncheckedRef<T: AnyObject>: @unchecked Sendable { let value: T; init(_ v: T) { value = v } }

final class StubProtocol: URLProtocol, @unchecked Sendable {
    private var work: Task<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        guard let port = request.url?.port, let server = StubServer.server(for: port) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let body = request.httpBody ?? request.httpBodyStream.map(Self.drain)
        let response = server.handle(request, body: body)
        let box = UncheckedRef(self)
        // At .high, like the timing tests (`.timely`, OffPool.swift): the
        // stub's own clock must not wait behind other tests' CPU work, or a
        // dribble looks like a stall.
        work = Task(priority: .high) {
            if response.delay > 0 {
                do { try await Task.sleep(nanoseconds: UInt64(response.delay * 1e9)) } catch { return }
            }
            let proto = box.value
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                       httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            proto.client?.urlProtocol(proto, didReceive: http, cacheStoragePolicy: .notAllowed)
            if !response.body.isEmpty { proto.client?.urlProtocol(proto, didLoad: response.body) }
            for chunk in response.chunks {
                do { try await Task.sleep(nanoseconds: UInt64(response.every * 1e9)) } catch { return }
                proto.client?.urlProtocol(proto, didLoad: chunk)
            }
            proto.client?.urlProtocolDidFinishLoading(proto)
        }
    }

    override func stopLoading() { work?.cancel() }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        return data
    }
}

func chatCompletion(_ content: String, prompt: Int = 100, completion: Int = 20) -> [String: Any] {
    ["choices": [["message": ["role": "assistant", "content": content]]],
     "usage": ["prompt_tokens": prompt, "completion_tokens": completion]]
}

// MARK: - Fake clock and power

final class FakeClock: OwlClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1_000
    private var sleepers: [UUID: (deadline: TimeInterval, c: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UUID> = []

    var now: TimeInterval { lock.withLock { t } }
    var pendingSleepers: Int { lock.withLock { sleepers.count } }

    func sleep(seconds: TimeInterval) async throws {
        if seconds <= 0 { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let resumeNow: Bool = lock.withLock {
                    if cancelled.remove(id) != nil { return true }
                    sleepers[id] = (t + seconds, c)
                    return false
                }
                if resumeNow { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Error>? = lock.withLock {
                if let s = sleepers.removeValue(forKey: id) { return s.c }
                cancelled.insert(id)
                return nil
            }
            c?.resume(throwing: CancellationError())
        }
    }

    func advance(_ dt: TimeInterval) {
        let due: [CheckedContinuation<Void, Error>] = lock.withLock {
            t += dt
            let ready = sleepers.filter { $0.value.deadline <= t }
            for k in ready.keys { sleepers.removeValue(forKey: k) }
            return ready.map { $0.value.c }
        }
        due.forEach { $0.resume() }
    }
}

final class FakePower: PowerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var state = PowerState.mains
    func set(_ s: PowerState) { lock.withLock { state = s } }
    func current() -> PowerState { lock.withLock { state } }
}

// MARK: - Fake providers

/// Counts calls; either answers at once or hangs until cancelled.
final class FakeProvider: OwlHintProvider, @unchecked Sendable {
    let name = "fake"
    let hang: Bool
    private let lock = NSLock()
    private var _calls: [Int] = []
    private var _cancellations = 0
    init(hang: Bool = false) { self.hang = hang }

    var calls: [Int] { lock.withLock { _calls } }
    var cancellations: Int { lock.withLock { _cancellations } }

    func hints(for context: OwlContext) async -> [OwlHint] {
        lock.withLock { _calls.append(context.editGeneration) }
        if hang {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000)
            }
            lock.withLock { _cancellations += 1 }
            return []
        }
        return [OwlHint(id: "h\(context.editGeneration)", kind: .tip, title: "t", detail: nil,
                        range: nil, replacement: nil, source: name)]
    }
}

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T { lock.withLock { _value } }
    func mutate(_ f: (inout T) -> Void) { lock.withLock { f(&_value) } }
}

/// Polls `cond` (real time) until true or ~8 s pass. It returns as soon as
/// `cond` holds, so the window only matters when a busy CI runner stalls
/// the work for seconds (2 s ran out in runs 44451577951, 44453003629).
func eventually(_ cond: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<1_600 {
        if await cond() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await cond()
}

func context(_ text: String = "let value = items.count + 1", gen: Int = 1, doc: UUID = UUID(),
             language: String = "swift", file: String? = "a.swift") -> OwlContext {
    OwlContext(fileName: file, language: language, text: text, textStart: 0,
               visibleRange: NSRange(location: 0, length: (text as NSString).length),
               selection: nil, documentID: doc, editGeneration: gen)
}
