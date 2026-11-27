import Testing
@testable import CedricCore

@Suite struct PixelSnapTests {
    @Test func roundsUpToAWholeBackingPixel() {
        // The split-restore case: line 120 at 2045.287 on a 1× display.
        #expect(PixelSnap.up(2045.287, scale: 1) == 2046)
        #expect(PixelSnap.up(2045.287, scale: 2) == 2045.5)
        #expect(PixelSnap.up(2045.6, scale: 2) == 2046)
        #expect(PixelSnap.up(2045.2, scale: 3) == 2045 + 1.0 / 3)
    }

    @Test func keepsAValueAlreadyOnAPixel() {
        #expect(PixelSnap.up(2045, scale: 1) == 2045)
        #expect(PixelSnap.up(2045.5, scale: 2) == 2045.5)
        #expect(PixelSnap.up(0, scale: 2) == 0)
        // Float noise above a pixel doesn't push a whole pixel further.
        #expect(PixelSnap.up(2045.0000000001, scale: 1) == 2045)
    }

    @Test func pixelSizeFollowsTheScale() {
        #expect(PixelSnap.pixel(scale: 1) == 1)
        #expect(PixelSnap.pixel(scale: 2) == 0.5)
        // No window yet (scale 0): treated as 1×.
        #expect(PixelSnap.pixel(scale: 0) == 1)
        #expect(PixelSnap.up(10.2, scale: 0) == 11)
    }
}
