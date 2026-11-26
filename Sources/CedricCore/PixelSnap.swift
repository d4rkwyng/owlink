import Foundation

/// Scroll positions in whole backing pixels. A scroll view only stops on
/// whole pixels, and TextKit 2's estimated line heights put a line's top
/// at a fractional y (2045.287), so scrolling there lands a fraction of a
/// pixel inside the line above.
public enum PixelSnap {
    /// `y` rounded up to a whole backing pixel at `scale` (1 or 2 …), so a
    /// line starting at `y` starts at or above the scrolled-to top. A value
    /// already on a pixel (within float noise) stays put.
    public static func up(_ y: Double, scale: Double) -> Double {
        let s = scale > 0 ? scale : 1
        return (y * s - 1e-6).rounded(.up) / s
    }

    /// One backing pixel: the tolerance for "already there" and how far
    /// below the visible top to look for the first visible line, so a line
    /// whose top lies less than a pixel above it doesn't count.
    public static func pixel(scale: Double) -> Double { 1 / (scale > 0 ? scale : 1) }
}
