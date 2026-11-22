import Foundation
import CoreGraphics

/// Where the owl sits over the editor, as a corner plus an inset from that
/// corner's two edges. Stored this way (not as an absolute point) so a
/// window resize keeps him the same distance from the same corner.
///
/// Dropping him snaps to the nearest edge, keeping his position along it,
/// and to the corner itself when he is dropped near one. Why not "stay
/// where dropped": in the middle of the editor he sits over text and the
/// fade-near-caret would keep firing as you type; along an edge he is out
/// of the text's way but still where you put him.
///
/// Coordinates are y-up (AppKit's default), origin bottom-left.
public struct OwlPlacement: Codable, Equatable, Sendable {
    public enum Corner: String, Codable, CaseIterable, Sendable {
        case bottomRight, bottomLeft, topRight, topLeft
        public var isRight: Bool { self == .bottomRight || self == .topRight }
        public var isTop: Bool { self == .topRight || self == .topLeft }
    }

    public var corner: Corner
    /// Distance from the corner's vertical edge (width) and horizontal edge (height).
    public var inset: CGSize

    public init(corner: Corner, inset: CGSize) {
        self.corner = corner
        self.inset = CGSize(width: max(0, inset.width), height: max(0, inset.height))
    }

    /// Bottom right, where he has always been.
    public static let margin = CGSize(width: 6, height: 2)
    public static let `default` = OwlPlacement(corner: .bottomRight, inset: margin)
    /// Dropped within this of a corner (along the edge he snaps to): into the corner.
    public static let cornerPull: CGFloat = 56
    /// Mouse movement before a press on the owl becomes a drag rather than a click.
    public static let dragThreshold: CGFloat = 3

    public static func isDrag(from a: CGPoint, to b: CGPoint, threshold: CGFloat = dragThreshold) -> Bool {
        hypot(b.x - a.x, b.y - a.y) >= threshold
    }

    /// The owl's frame origin for this placement in `bounds`, clamped so he
    /// is always wholly inside (a window shrunk smaller than his inset).
    public func origin(in bounds: CGRect, size: CGSize) -> CGPoint {
        let x = corner.isRight ? bounds.maxX - size.width - inset.width : bounds.minX + inset.width
        let y = corner.isTop ? bounds.maxY - size.height - inset.height : bounds.minY + inset.height
        return Self.clamp(CGPoint(x: x, y: y), size: size, in: bounds)
    }

    /// Keeps a frame of `size` at `origin` inside `bounds` (pinned to the
    /// bottom-left when bounds are smaller than the owl).
    public static func clamp(_ origin: CGPoint, size: CGSize, in bounds: CGRect) -> CGPoint {
        CGPoint(x: max(bounds.minX, min(origin.x, bounds.maxX - size.width)),
                y: max(bounds.minY, min(origin.y, bounds.maxY - size.height)))
    }

    /// The placement for an owl dropped with its frame at `origin`: snapped
    /// to the nearest edge (corner when close to one), then described from
    /// the nearest corner.
    public static func snapped(origin: CGPoint, size: CGSize, in bounds: CGRect) -> OwlPlacement {
        let o = clamp(origin, size: size, in: bounds)
        let left = o.x - bounds.minX, right = bounds.maxX - (o.x + size.width)
        let bottom = o.y - bounds.minY, top = bounds.maxY - (o.y + size.height)
        let isRight = right < left, isTop = top < bottom
        var dx = isRight ? right : left
        var dy = isTop ? top : bottom
        // Snap the nearer edge to the margin; the other axis stays put
        // unless it is near the corner too.
        if dx <= dy {
            dx = margin.width
            if dy <= cornerPull { dy = margin.height }
        } else {
            dy = margin.height
            if dx <= cornerPull { dx = margin.width }
        }
        let corner: Corner = isTop ? (isRight ? .topRight : .topLeft) : (isRight ? .bottomRight : .bottomLeft)
        return OwlPlacement(corner: corner, inset: CGSize(width: dx, height: dy))
    }

    /// Where the speech bubble goes: above the owl when there's room (else
    /// below), and towards the side of the editor with more room, its tail
    /// pointing at him.
    public struct Bubble: Equatable, Sendable {
        public var frame: CGRect
        public var tailOnTop: Bool
        public var tailAtLeft: Bool
    }

    /// The same, kept off `avoid` (the lines the hint is about) when it
    /// can be: the other side of the owl (above or below), then sliding
    /// along the editor's width, still inside `bounds`. As before when
    /// nothing avoids it.
    public static func bubble(owl: CGRect, size: CGSize, in bounds: CGRect, avoid: CGRect?) -> Bubble {
        let plain = bubble(owl: owl, size: size, in: bounds)
        guard let avoid, !avoid.isEmpty, plain.frame.intersects(avoid) else { return plain }
        let overlap = owl.height * 0.3
        let towardsLeft = !plain.tailAtLeft
        var candidates: [Bubble] = []
        // Above and below the owl, at the usual x, then at the far sides.
        let xs = [plain.frame.minX, bounds.minX + 4, bounds.maxX - size.width - 4]
        for above in [plain.tailOnTop, !plain.tailOnTop] {
            let y = above ? owl.maxY - overlap : owl.minY + 2 - size.height
            for x in xs {
                candidates.append(Bubble(frame: CGRect(x: x, y: y, width: size.width, height: size.height),
                                         tailOnTop: !above, tailAtLeft: !towardsLeft))
            }
        }
        // Clear of the hinted lines above or below them, by the owl's side.
        for y in [avoid.maxY + 4, avoid.minY - 4 - size.height] {
            candidates.append(Bubble(frame: CGRect(x: plain.frame.minX, y: y, width: size.width, height: size.height),
                                     tailOnTop: y < owl.minY, tailAtLeft: plain.tailAtLeft))
        }
        if let clear = candidates.first(where: { bounds.contains($0.frame) && !$0.frame.intersects(avoid) }) { return clear }
        // No room anywhere (a tiny window): as before. The bubble fades
        // when the caret comes near it.
        return plain
    }

    public static func bubble(owl: CGRect, size: CGSize, in bounds: CGRect) -> Bubble {
        // Over his head, overlapping the top 30% of the art (as before).
        let overlap = owl.height * 0.3
        let roomAbove = bounds.maxY - (owl.maxY - overlap)
        let roomBelow = (owl.minY + 2) - bounds.minY
        let above = roomAbove >= size.height || roomAbove >= roomBelow
        // Extends away from the nearer side wall.
        let towardsLeft = (bounds.maxX - owl.midX) < (owl.midX - bounds.minX)
        var x = towardsLeft ? owl.maxX - size.width + 2 : owl.minX - 2
        x = max(bounds.minX + 4, min(x, bounds.maxX - size.width - 4))
        // Below: just under his feet (the art fills the view's bottom edge).
        let y = above ? owl.maxY - overlap : owl.minY + 2 - size.height
        return Bubble(frame: CGRect(x: x, y: y, width: size.width, height: size.height),
                      tailOnTop: !above, tailAtLeft: !towardsLeft)
    }
}

// MARK: UIKit (y-down) coordinates

/// The same rules for a y-down (UIKit) view: the iOS app's owl. The math
/// is the y-up one above, flipped inside `area`, so the Mac and iOS owls
/// snap, clamp and place their bubble identically.
extension OwlPlacement {
    /// Flips a rect between y-up and y-down inside `area` (its own inverse).
    public static func flipped(_ r: CGRect, in area: CGRect) -> CGRect {
        CGRect(x: r.minX, y: area.minY + area.maxY - r.maxY, width: r.width, height: r.height)
    }

    /// His frame in a y-down `area`.
    public func frameYDown(in area: CGRect, size: CGSize) -> CGRect {
        Self.flipped(CGRect(origin: origin(in: area, size: size), size: size), in: area)
    }

    /// A bottom slot in a trailing navigation rail, in y-down window coordinates.
    /// On the Duo, an 84 pt trailing safe inset has its centre at x=424 in
    /// a 466 pt window; the rail buttons centre at x=417.5. The 6.5 pt
    /// correction follows that column. The controls aren't exposed as UIKit
    /// views: with the clock shown they end at 425–446 pt, without it at
    /// about 295 pt. Reserve 460 or 310 pt respectively from the window top.
    public enum RailOwlSlot {
        private static let controlsBottomWithStatus: CGFloat = 460
        private static let controlsBottomWithoutStatus: CGFloat = 310
        private static let columnCorrection: CGFloat = 6.5
        private static let minimumTrailingInset: CGFloat = 60
        private static let minimumInsetDifference: CGFloat = 30

        public static func railControlsBottom(statusBarShown: Bool) -> CGFloat {
            statusBarShown ? controlsBottomWithStatus : controlsBottomWithoutStatus
        }

        public static func frame(screen: CGRect, safe: CGRect, navigationBar: CGRect, statusTop: CGFloat, statusBarShown: Bool,
                                 size: CGSize, margin: CGFloat = 4) -> CGRect? {
            let leading = safe.minX - screen.minX
            let trailing = screen.maxX - safe.maxX
            guard !screen.isNull, !screen.isEmpty, !safe.isNull, !safe.isEmpty,
                  size.width > 0, size.height > 0, margin >= 0,
                  trailing >= minimumTrailingInset, trailing >= leading + minimumInsetDifference,
                  navigationBar.height > 0, navigationBar.width >= navigationBar.height * 2 else { return nil }
            let x = screen.maxX - trailing / 2 - columnCorrection - size.width / 2
            let y = min(safe.maxY, screen.maxY, statusTop) - margin - size.height
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            guard frame.minX >= screen.minX + margin, frame.maxX <= screen.maxX - margin,
                  frame.minY >= max(safe.minY, screen.minY + railControlsBottom(statusBarShown: statusBarShown)) + margin else { return nil }
            return frame
        }
    }

    /// The placement for an owl dropped at y-down `frame` in `area`.
    public static func snapped(frameYDown frame: CGRect, in area: CGRect) -> OwlPlacement {
        snapped(origin: flipped(frame, in: area).origin, size: frame.size, in: area)
    }

    /// The bubble for a y-down owl frame, avoiding y-down `avoid`; the
    /// result is y-down (`tailOnTop` true means the tail points up at him,
    /// i.e. the bubble is below him on screen).
    public static func bubbleYDown(owl: CGRect, size: CGSize, in area: CGRect, avoid: CGRect?) -> Bubble {
        let b = bubble(owl: flipped(owl, in: area), size: size, in: area, avoid: avoid.map { flipped($0, in: area) })
        // y-up "tail on top" = bubble below him; on screen that is still
        // below him with the tail pointing up, so the flag carries over.
        return Bubble(frame: flipped(b.frame, in: area), tailOnTop: b.tailOnTop, tailAtLeft: b.tailAtLeft)
    }

    /// Keeps a frame off the fold (iPhone Duo's division regions, y-down or
    /// y-up alike: only x is used): moved to the side of the fold its centre
    /// is on, by `gap`, and kept inside `area` horizontally. Folds that don't
    /// cross the frame are ignored.
    public static func avoidingFolds(_ frame: CGRect, folds: [CGRect], in area: CGRect, gap: CGFloat = 8) -> CGRect {
        var f = frame
        for fold in folds where fold.width >= 0 && f.minX < fold.maxX && f.maxX > fold.minX
            && f.minY < fold.maxY && f.maxY > fold.minY {
            f.origin.x = f.midX < fold.midX ? fold.minX - gap - f.width : fold.maxX + gap
        }
        f.origin.x = max(area.minX, min(f.origin.x, area.maxX - f.width))
        return f
    }
}
