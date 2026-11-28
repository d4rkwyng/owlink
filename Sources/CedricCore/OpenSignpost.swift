import Foundation
import os

/// os_signpost intervals around opening a file into a tab (a folder
/// sidebar click, File › Open, Finder): subsystem the bundle id, category
/// "SidebarOpen". Instruments shows them (os_signpost, Points of
/// Interest); when nothing records, an interval costs about as much as a
/// branch. Check builds (CEDRIC_CHECKS) can also add the phases up in
/// process for one open at a time (`startRecording`, `stopRecording`):
/// the sidebar click benchmark (SidebarClickCheck.swift) prints them.
public enum OpenSignpost {
    public static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "net.mindtricks.cedric",
                                                category: "SidebarOpen")

    /// `body` inside an interval named `name`.
    @inline(__always)
    public static func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        #if CEDRIC_CHECKS
        let t0 = recorder.withLock { $0 != nil } ? ProcessInfo.processInfo.systemUptime : nil
        defer { if let t0 { record(name, ProcessInfo.processInfo.systemUptime - t0) } }
        #endif
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// A point in time (an event in Instruments).
    @inline(__always)
    public static func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    #if CEDRIC_CHECKS
    /// Seconds per phase since `startRecording` (summed when a phase runs
    /// more than once); off the main thread under "bg:" + its name.
    private static let recorder = OSAllocatedUnfairLock<[String: Double]?>(initialState: nil)

    private static func record(_ name: StaticString, _ seconds: Double) {
        let key = Thread.isMainThread ? "\(name)" : "bg:\(name)"
        recorder.withLock { phases in phases?[key, default: 0] += seconds }
    }

    public static func startRecording() { recorder.withLock { $0 = [:] } }

    /// The phases since `startRecording`, in seconds; recording stops.
    public static func stopRecording() -> [String: Double] {
        recorder.withLock { phases in
            defer { phases = nil }
            return phases ?? [:]
        }
    }
    #endif
}
