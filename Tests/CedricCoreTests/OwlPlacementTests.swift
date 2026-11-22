import CoreGraphics
import Foundation
import Testing
@testable import CedricCore

@Suite struct OwlPlacementTests {
    let owl = CGSize(width: 72, height: 72)
    let editor = CGRect(x: 0, y: 0, width: 800, height: 600)

    @Test func defaultIsBottomRightAsBefore() {
        let o = OwlPlacement.default.origin(in: editor, size: owl)
        #expect(o == CGPoint(x: 800 - 72 - 6, y: 2))
    }

    @Test func dragThreshold() {
        let a = CGPoint(x: 10, y: 10)
        #expect(!OwlPlacement.isDrag(from: a, to: CGPoint(x: 12, y: 11)))      // 2.2 pt: a click
        #expect(!OwlPlacement.isDrag(from: a, to: CGPoint(x: 12.9, y: 10)))
        #expect(OwlPlacement.isDrag(from: a, to: CGPoint(x: 13, y: 10)))        // 3 pt: a drag
        #expect(OwlPlacement.isDrag(from: a, to: CGPoint(x: 8, y: 13)))
    }

    @Test func dropNearTopLeftSnapsIntoTheCorner() {
        let p = OwlPlacement.snapped(origin: CGPoint(x: 30, y: 600 - 72 - 40), size: owl, in: editor)
        #expect(p == OwlPlacement(corner: .topLeft, inset: OwlPlacement.margin))
        #expect(p.origin(in: editor, size: owl) == CGPoint(x: 6, y: 600 - 72 - 2))
    }

    @Test func dropMidBottomSnapsToTheEdgeKeepingX() {
        // Nearer the left wall, well away from both corners.
        let p = OwlPlacement.snapped(origin: CGPoint(x: 250, y: 20), size: owl, in: editor)
        #expect(p.corner == .bottomLeft)
        #expect(p.inset == CGSize(width: 250, height: OwlPlacement.margin.height))
    }

    @Test func dropMidRightEdgeSnapsToTheEdgeKeepingY() {
        let p = OwlPlacement.snapped(origin: CGPoint(x: 800 - 72 - 30, y: 400), size: owl, in: editor)
        #expect(p.corner == .topRight)
        #expect(p.inset == CGSize(width: OwlPlacement.margin.width, height: 600 - 472))
    }

    @Test func dropOutsideIsClamped() {
        let p = OwlPlacement.snapped(origin: CGPoint(x: -400, y: 9000), size: owl, in: editor)
        #expect(p == OwlPlacement(corner: .topLeft, inset: OwlPlacement.margin))
    }

    @Test func cornerAndInsetSurviveResizes() {
        let p = OwlPlacement.snapped(origin: CGPoint(x: 250, y: 600 - 72), size: owl, in: editor) // top edge, 250 from left
        #expect(p.corner == .topLeft)
        let bigger = CGRect(x: 0, y: 0, width: 1400, height: 900)
        #expect(p.origin(in: bigger, size: owl) == CGPoint(x: 250, y: 900 - 72 - 2))
        // Top-right keeps its distance from the right edge as the window grows.
        let tr = OwlPlacement(corner: .topRight, inset: CGSize(width: 6, height: 2))
        let trx = tr.origin(in: bigger, size: owl).x
        #expect(trx == 1322, "x=\(trx)")
        // Shrunk below the inset: clamped inside, never off-screen.
        let small = CGRect(x: 0, y: 0, width: 200, height: 120)
        let o = p.origin(in: small, size: owl)
        #expect(o.x == 200 - 72 && o.y == 120 - 72 - 2)
        // Codable round trip (how it's saved).
        let data = try! JSONEncoder().encode(p)
        #expect(try! JSONDecoder().decode(OwlPlacement.self, from: data) == p)
    }

    @Test func bubbleOpensOnTheSideWithRoom() {
        let size = CGSize(width: 240, height: 90)
        // Bottom right: above him, extending left, tail bottom right.
        let br = CGRect(origin: OwlPlacement.default.origin(in: editor, size: owl), size: owl)
        let a = OwlPlacement.bubble(owl: br, size: size, in: editor)
        #expect(!a.tailOnTop && !a.tailAtLeft)
        #expect(a.frame.minY > br.minY && a.frame.maxX <= editor.maxX)
        // Top left: below him, extending right, tail top left.
        let tl = CGRect(origin: CGPoint(x: 6, y: 600 - 74), size: owl)
        let b = OwlPlacement.bubble(owl: tl, size: size, in: editor)
        #expect(b.tailOnTop && b.tailAtLeft)
        #expect(b.frame.maxY < tl.maxY && b.frame.minX >= editor.minX && b.frame.minY >= editor.minY)
    }

    @Test func railSlotIsAtSafeBottomAndClearOfControls() throws {
        let screen = CGRect(x: 0, y: 0, width: 466, height: 678)
        let safe = CGRect(x: 0, y: 0, width: 382, height: 644)
        let bar = CGRect(x: 0, y: 24, width: 466, height: 58)
        let size = CGSize(width: 64, height: 64)
        let slot = try #require(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: bar, statusTop: 644, statusBarShown: true, size: size))
        #expect(slot == CGRect(x: 385.5, y: 576, width: 64, height: 64))
        #expect(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: bar, statusTop: 500, statusBarShown: true, size: size) == nil)
        let symmetricNotch = CGRect(x: 84, y: 0, width: 298, height: 644)
        #expect(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: symmetricNotch, navigationBar: bar, statusTop: 644, statusBarShown: true, size: size) == nil)
        let portraitSafe = CGRect(x: 0, y: 24, width: 466, height: 620)
        #expect(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: portraitSafe, navigationBar: bar, statusTop: 644, statusBarShown: true, size: size) == nil)
        let verticalBar = CGRect(x: 411, y: 0, width: 55, height: 678)
        #expect(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: verticalBar, statusTop: 644, statusBarShown: true, size: size) == nil)
        #expect(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: bar, statusTop: 531, statusBarShown: true, size: size) == nil)
        #expect(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: bar, statusTop: 532, statusBarShown: true, size: size) != nil)
        let wide = CGRect(x: 0, y: 0, width: 1024, height: 720)
        let wideSafe = CGRect(x: 0, y: 0, width: 940, height: 686)
        let wideBar = CGRect(x: 0, y: 24, width: 1024, height: 58)
        #expect(OwlPlacement.RailOwlSlot.frame(screen: wide, safe: wideSafe, navigationBar: wideBar,
                                              statusTop: 686, statusBarShown: true, size: size) == CGRect(x: 943.5, y: 618, width: 64, height: 64))
        let shifted = screen.offsetBy(dx: 20, dy: 30)
        let shiftedSlot = OwlPlacement.RailOwlSlot.frame(screen: shifted, safe: safe.offsetBy(dx: 20, dy: 30),
                                                         navigationBar: bar.offsetBy(dx: 20, dy: 30), statusTop: 674, statusBarShown: true, size: size)
        #expect(shiftedSlot == slot.offsetBy(dx: 20, dy: 30))
        let pane = CGRect(x: 4, y: 86, width: 374, height: 554)
        let bubble = OwlPlacement.bubbleYDown(owl: slot, size: CGSize(width: 240, height: 90), in: pane, avoid: nil)
        #expect(bubble.frame.maxX <= pane.maxX && bubble.frame.minY < slot.minY)
        #expect(!bubble.tailOnTop && !bubble.tailAtLeft)
    }

    @Test func railInsetThresholds() {
        let screen = CGRect(x: 0, y: 0, width: 466, height: 678)
        let bar = CGRect(x: 0, y: 24, width: 466, height: 58)
        let size = CGSize(width: 64, height: 64)
        func slot(leading: CGFloat, trailing: CGFloat) -> CGRect? {
            let safe = CGRect(x: leading, y: 0, width: screen.width - leading - trailing, height: 644)
            return OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: bar,
                                                  statusTop: 644, statusBarShown: true, size: size)
        }
        #expect(slot(leading: 0, trailing: 59) == nil)
        #expect(slot(leading: 0, trailing: 60) != nil)
        #expect(slot(leading: 31, trailing: 60) == nil)
        #expect(slot(leading: 30, trailing: 60) != nil)
    }

    @Test func railSlotFitsShortLandscapeWithoutClock() throws {
        let screen = CGRect(x: 0, y: 0, width: 678, height: 466)
        let safe = CGRect(x: 0, y: 0, width: 594, height: 432)
        let bar = CGRect(x: 0, y: 0, width: 678, height: 58)
        let size = CGSize(width: 64, height: 64)
        let slot = try #require(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: bar,
                                                               statusTop: 432, statusBarShown: false, size: size))
        #expect(slot == CGRect(x: 597.5, y: 364, width: 64, height: 64))
        #expect(slot.minY >= 314 && slot.maxY <= 428)
        #expect(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: bar,
                                              statusTop: 432, statusBarShown: true, size: size) == nil)
        #expect(OwlPlacement.RailOwlSlot.frame(screen: screen, safe: safe, navigationBar: bar,
                                              statusTop: 381, statusBarShown: false, size: size) == nil)
    }
}
