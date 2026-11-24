import Foundation

/// One Ask Cedric panel's request in flight. A new question (typed, a
/// quick action, Review, Explain, Check for Risks), closing the panel or
/// Stop cancels the one before it: its task is cancelled, which reaches
/// the engine (the built-in model's per-request cancel aborts its prefill
/// or decode; a server request is dropped), and it stops being current, so
/// nothing it still delivers (streamed text, a late answer, an error)
/// reaches the new question's thread. The user never has to press Stop
/// first, and a question abandoned mid-prefill can't leave the next one
/// waiting behind it on "…".
@MainActor
public final class OwlAskLifecycle {
    public struct Ticket: Equatable, Sendable {
        let id: Int
    }

    private var nextID = 0
    public private(set) var current: Ticket?
    private var task: Task<Void, Never>?
    /// When the current request started (the waiting label's elapsed time).
    public private(set) var startedAt: Date?
    /// Requests cancelled before they finished (tests, checks).
    public private(set) var cancelledCount = 0

    public init() {}

    public var isRunning: Bool { current != nil }

    /// Cancels and abandons whatever is running, then runs `work` as the
    /// current request. Called inside a task-local scope (`BuiltInLoad`),
    /// the task inherits it.
    @discardableResult
    public func start(now: Date = Date(), _ work: @escaping @MainActor (Ticket) async -> Void) -> Ticket {
        cancel()
        nextID += 1
        let t = Ticket(id: nextID)
        current = t
        startedAt = now
        task = Task { @MainActor in await work(t) }
        return t
    }

    /// Is `t` still the panel's request? Everything a request delivers
    /// (text, tool notes, its answer, its error) is dropped once it isn't.
    public func isCurrent(_ t: Ticket) -> Bool { current == t }

    /// Stop that waits for what the request makes of being cancelled (a
    /// chunked review keeps the parts it finished): the task is cancelled,
    /// the request stays current until it returns.
    public func stopWaiting() { task?.cancel() }

    /// Cancels the running request and abandons it now.
    public func cancel() {
        guard current != nil else { return }
        task?.cancel()
        cancelledCount += 1
        task = nil
        current = nil
        startedAt = nil
    }

    /// `t` finished (answered, failed or stopped): no longer current.
    public func finished(_ t: Ticket) {
        guard current == t else { return }
        task = nil
        current = nil
        startedAt = nil
    }

    /// Seconds since the current request started (0 when none).
    public func elapsed(now: Date = Date()) -> TimeInterval {
        startedAt.map { max(0, now.timeIntervalSince($0)) } ?? 0
    }
}

/// What the transcript shows while Cedric hasn't written anything yet
/// (the model is loading or processing the prompt, which for a whole file
/// can take minutes on the built-in engine): never a bare "…".
public enum OwlAskWaiting {
    /// "Processing prompt… 12 s".
    public static func label(elapsed: TimeInterval, searching: Bool = false) -> String {
        let what = searching ? "Looking through the file…" : "Processing prompt…"
        return what + " " + time(elapsed)
    }

    /// "Stop · 1:05" while an answer streams.
    public static func stopTitle(elapsed: TimeInterval) -> String { "Stop · " + time(elapsed) }

    /// "0 s", "59 s", "1:05", "12:00".
    public static func time(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s) s" }
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
