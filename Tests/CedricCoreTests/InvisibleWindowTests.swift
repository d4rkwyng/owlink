import Foundation
import Testing
@testable import CedricCore

@Suite struct InvisibleWindowTests {
    @Test func boundsAndFallback() {
        let line = NSRange(location: 100, length: 10_000)
        #expect(InvisibleWindow.range(in: line, left: nil, right: 200) == NSRange(location: 100, length: 4096))
        #expect(InvisibleWindow.range(in: line, left: -500, right: -400) == NSRange(location: 100, length: 1))
        #expect(InvisibleWindow.range(in: line, left: 20_000, right: 30_000) == NSRange(location: 10_099, length: 1))
        #expect(InvisibleWindow.range(in: line, left: 600, right: 500) == NSRange(location: 499, length: 102))
        #expect(InvisibleWindow.range(in: line, left: 100, right: 10_100).length == 4096)
        let short = NSRange(location: 10, length: 30)
        #expect(InvisibleWindow.range(in: short, left: nil, right: nil) == short)
    }
}
