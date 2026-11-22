import Foundation

/// Limits work on an unwrapped line to the visible UTF-16 window.
public enum InvisibleWindow {
    public static let limit = 4096

    public static func range(in line: NSRange, left: Int?, right: Int?) -> NSRange {
        guard line.length > limit else { return line }
        guard let left, let right else {
            return NSRange(location: line.location, length: limit)
        }
        let end = NSMaxRange(line)
        let a = min(end, max(line.location, left))
        let b = min(end, max(line.location, right))
        let start = max(line.location, min(a, b) - 1)
        let stop = min(end, max(a, b) + 1)
        return NSRange(location: start, length: min(limit, stop - start))
    }
}
