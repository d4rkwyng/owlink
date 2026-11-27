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
        /// Virtual time (the client's `streamClock`): `delay` and `every`
        /// advance this clock instead of being slept, so only the
        /// client's logic, not how busy the runner is, decides whether a
        /// deadline passes. See `StreamClock`.
        var clock: StreamClock? = nil
        /// On virtual time: chunk `i` is held, and the clock doesn't move
        /// to it, until the client's `onText` has delivered `heard[i]` in
        /// all (`StreamClock.hear`). So the clock can't move on while the
        /// reader is still parsing (and touching on) the chunk before.
        var heard: [Int: String] = [:]
    }
    typealias Handler = @Sendable (URLRequest, Data?) -> Response

    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [Int: StubServer] = [:]
    nonisolated(unsafe) private static var nextPort = 40_000

    let port: Int
    private let lock = NSLock()
    private var routes: [String: Handler] = [:]
    private(set) var requests: [(path: String, body: Data?)] = []
    private var timeouts: [(path: String, timeout: TimeInterval)] = []

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
    /// Each request's own `timeoutInterval`, as the stub received it.
    var recordedTimeouts: [(path: String, timeout: TimeInterval)] { lock.withLock { timeouts } }

    fileprivate static func server(for port: Int) -> StubServer? { lock.withLock { servers[port] } }

    fileprivate func handle(_ request: URLRequest, body: Data?) -> Response {
        let path = request.url?.path ?? ""
        let handler: Handler? = lock.withLock {
            requests.append((path, body))
            timeouts.append((path, request.timeoutInterval))
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
        if let clock = response.clock {
            work = Task(priority: .high) { await Self.play(response, on: clock, request: request, box: box) }
            return
        }
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

    /// `response` on virtual time, in step with the client:
    /// - the headers wait until the client's deadline loop has read the
    ///   clock (it is running);
    /// - each chunk but the last waits until the client has read a byte of
    ///   it and stored the touch (`streamTouched`: after `last` is set, with
    ///   the bytes read so far and the time stored), at the chunk's virtual
    ///   time. A touch the reader has read the clock for but not stored, or
    ///   a late one for an earlier chunk (too few bytes), doesn't count. So
    ///   the stub never runs ahead of a stalled reader and makes a gap the
    ///   client never saw;
    /// - a chunk with a `heard` entry waits, before the clock moves to it,
    ///   until `onText` has delivered that text;
    /// - the last chunk waits until the deadline loop has read the clock
    ///   twice at the full virtual length of the answer. The loop only
    ///   reads again after it found time left (`remaining() > 0`, then a
    ///   sleep); a deadline that passed (first byte, or an idle limit a
    ///   chunk didn't reset) ends the loop at the first read, the stream
    ///   ends with `.timedOut`, and the last chunk is never sent (the load
    ///   is cancelled while the stub waits). So the client has decided at
    ///   that instant before the last chunk can race its decision.
    /// Any of those that doesn't come in time (30 s for the deadline loop,
    /// 10 s for a touch or text; all far above a runner's stalls) fails the
    /// load at once with `URLError(.resourceUnavailable)`. The stub never
    /// plays on out of step, so virtual time can't jump past a deadline
    /// the client hasn't seen, and a reader that doesn't start its deadline
    /// loop or doesn't touch on some kind of chunk fails in seconds.
    private static func play(_ response: StubServer.Response, on clock: StreamClock,
                             request: URLRequest, box: UncheckedRef<StubProtocol>) async {
        let proto = box.value
        let started = await clock.wait(atMost: 30) { $0.deadlineReads > 0 }
        if Task.isCancelled { return }
        guard started else { return fail(proto, "the deadline loop never read the clock") }
        clock.advance(response.delay)
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        proto.client?.urlProtocol(proto, didReceive: http, cacheStoragePolicy: .notAllowed)
        if !response.body.isEmpty { proto.client?.urlProtocol(proto, didLoad: response.body) }
        var sent = response.body.count
        for (i, chunk) in response.chunks.enumerated() {
            // Real time only to keep chunks apart: 20 ms > the 10 ms in
            // which `StreamWatch` takes bytes as one chunk.
            do { try await Task.sleep(nanoseconds: 20_000_000) } catch { return }
            if let want = response.heard[i] {
                let heard = await clock.wait(atMost: 10) { $0.heard == want }
                if Task.isCancelled { return }
                guard heard else { return fail(proto, "onText never delivered \(want.debugDescription) before chunk \(i)") }
            }
            clock.advance(response.every)
            let last = i == response.chunks.count - 1
            if last {
                // Counted after the advance: both reads are at the final time.
                let seen = clock.deadlineReads
                let decided = await clock.wait(atMost: 30) { $0.deadlineReads >= seen + 2 }
                // A deadline that passed: the client cancels the load
                // (stopLoading) and the last chunk is never sent.
                if Task.isCancelled { return }
                // The deadline loop never found time left at the final
                // time, nor ended the stream: the last chunk is withheld
                // and the load fails, so the test can't pass without that
                // check having run.
                guard decided else { return fail(proto, "the deadline loop didn't find time left before the last chunk") }
            }
            let before = sent, at = clock.now
            proto.client?.urlProtocol(proto, didLoad: chunk)
            sent += chunk.count
            if !last {
                // Not touched: fail here rather than advance the clock past
                // a gap the reader never saw. Only a stored touch on a byte
                // of this chunk, at its time, counts.
                let read = await clock.wait(atMost: 10) {
                    guard let c = $0.lastTouch else { return false }
                    return c.bytesRead > before && c.at >= at
                }
                if Task.isCancelled { return }
                guard read else { return fail(proto, "chunk \(i) was never read (no stored touch)") }
            }
        }
        proto.client?.urlProtocolDidFinishLoading(proto)
    }

    private static func fail(_ proto: StubProtocol, _ why: String) {
        proto.client?.urlProtocol(proto, didFailWithError: URLError(.resourceUnavailable, userInfo: [
            NSLocalizedDescriptionKey: "stub: \(why)"]))
    }

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

/// Virtual time for a streamed answer (`LocalModelClient.streamClock`),
/// moved only by the stub (`StubServer.Response.clock`): a runner stalled
/// for seconds can't turn a 0.2 s gap into a missed deadline.
///
/// Who reads it tells the stub what the client has done. The first reader
/// is `StreamWatch.init` (the calling task); the next is the client's
/// deadline loop (`remaining()`, which runs before any byte exists: the
/// stub holds the headers until then); any other task is the one reading
/// the bytes, touching the watch on a chunk.
final class StreamClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1_000
    private var tasks: [Int] = []          // in first-read order
    private var counts: [Int] = [0, 0, 0]  // reads by: creator, deadline loop, byte reader

    /// For `streamClock`.
    var read: @Sendable () -> TimeInterval { { [self] in self.readNow() } }

    private func readNow() -> TimeInterval {
        let id = withUnsafeCurrentTask { $0?.hashValue } ?? 0
        return lock.withLock {
            if !tasks.contains(id) { tasks.append(id) }
            counts[min(2, tasks.firstIndex(of: id)!)] += 1
            return t
        }
    }

    /// Now, without counting as a read.
    var now: TimeInterval { lock.withLock { t } }
    var deadlineReads: Int { lock.withLock { counts[1] } }
    var touchReads: Int { lock.withLock { counts[2] } }

    func advance(_ dt: TimeInterval) { lock.withLock { t += dt } }

    private var _lastTouch: (at: TimeInterval, bytesRead: Int)?
    /// The client's latest stored touch of its watch (`touched`).
    var lastTouch: (at: TimeInterval, bytesRead: Int)? { lock.withLock { _lastTouch } }
    /// For `streamTouched`: called after the watch has stored the touch.
    var touched: @Sendable (TimeInterval, Int) -> Void {
        { [self] at, n in self.lock.withLock { self._lastTouch = (at, n) } }
    }

    private var _heard = ""
    /// All the text `onText` has delivered (`hear`).
    var heard: String { lock.withLock { _heard } }
    /// For a test's `onText`: lets the stub hold a chunk until this text
    /// is in (`StubServer.Response.heard`).
    func hear(_ text: String) { lock.withLock { _heard += text } }

    /// Polls (real, monotonic time) until `cond` holds, the task is
    /// cancelled, or `atMost` seconds pass; whether `cond` held.
    func wait(atMost: TimeInterval, _ cond: (StreamClock) -> Bool) async -> Bool {
        let end = ContinuousClock.now.advanced(by: .milliseconds(Int64(atMost * 1000)))
        while !cond(self) {
            if Task.isCancelled || ContinuousClock.now > end { return false }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        return true
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

/// Polls `cond` (real time) until true or ~`seconds` pass (8 by default).
/// It returns as soon as `cond` holds, so the window only matters when a
/// busy CI runner stalls the work for seconds (2 s ran out in runs
/// 44451577951, 44453003629).
func eventually(seconds: Double = 8, _ cond: @Sendable () async -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 200) {
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

// MARK: - No real-time deadline

extension LocalModelClient {
    /// This client with a deadline (`withDeadline`) that never passes on
    /// its own, a stream clock that doesn't move (so a stream's first-byte,
    /// idle and cap limits never pass either), and no timeout of
    /// URLSession's own on its requests (`requestTimeout`): it only ends
    /// when the request does, so the client's own
    /// logic (the answer, an error, the policy), not how long a busy CI
    /// runner takes to schedule URLSession's work, decides the result. For
    /// tests whose point isn't the deadline; they carry a `.timeLimit` so
    /// a hang still ends. `asked` gets each deadline's length in seconds.
    func withoutRealDeadline(_ asked: Locked<[TimeInterval]>? = nil) -> LocalModelClient {
        var c = self
        c.requestTimeout = .infinity
        c.streamClock = { 0 }
        c.deadlineSleep = { seconds in
            asked?.mutate { $0.append(seconds) }
            while true { try await Task.sleep(nanoseconds: 3_600 * 1_000_000_000) }
        }
        return c
    }
}

/// Time that never passes: `RedirectGuard.checkPeers` on it polls (really
/// sleeping what it asks) until URLSession has reported the connection,
/// however late that is on a busy runner. The test's `.timeLimit` bounds it.
struct FrozenClock: OwlClock {
    var now: TimeInterval { 0 }
    func sleep(seconds: TimeInterval) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }
}
