import XCTest
import UIKit
import CedricCore

/// A viewer's security scope ends with its window: a scene that
/// disconnects without Done tears its viewers down (`sceneDidDisconnect`),
/// and each scope that started is stopped exactly once.
@MainActor
final class DocumentViewerTeardownTests: XCTestCase {
    private var starts = 0
    private var stops = 0
    private var windows: [UIWindow] = []

    override func tearDown() async throws {
        for w in windows { w.isHidden = true }
        windows = []
    }

    private let url = FileManager.default.temporaryDirectory.appendingPathComponent("teardown-\(UUID().uuidString).xlsx")

    private func access(started: Bool = true) -> ScopedFileAccess {
        ScopedFileAccess(url, startAccess: { [unowned self] _ in starts += 1; return started },
                         stopAccess: { [unowned self] _ in stops += 1 })
    }

    private func viewerNav(started: Bool = true) -> UINavigationController {
        UINavigationController(rootViewController: QuickLookViewerController(url: url, format: .spreadsheet, access: access(started: started)))
    }

    func testScopeStopsOnceHoweverOftenItIsStopped() {
        let a = access()
        a.stop()
        a.stop()
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(stops, 1)
        // A scope that didn't start (a file in the app's container) stops nothing.
        let b = access(started: false)
        b.stop()
        XCTAssertEqual(stops, 1)
        _ = b
    }

    /// N viewers' scopes started: N stops after teardown; tearing down again,
    /// or the viewers going away, stops nothing more.
    func testTeardownStopsEveryStartedScopeOnce() {
        var navs: [UINavigationController]? = (0..<3).map { _ in viewerNav() }
        let viewers = DocumentViewers.viewers(in: navs!)
        XCTAssertEqual(viewers.count, 3)
        XCTAssertEqual(starts, 3)
        XCTAssertEqual(stops, 0)
        DocumentViewers.tearDown(viewers)
        XCTAssertEqual(stops, 3)
        DocumentViewers.tearDown(viewers)
        XCTAssertEqual(stops, 3, "a second teardown is a no-op")
        navs = nil
        XCTAssertEqual(stops, 3, "deinit after teardown stops nothing more")
    }

    /// What `sceneDidDisconnect` does: the viewer the window presents is
    /// torn down (its scope stopped) without Done being tapped.
    func testWindowTeardownStopsThePresentedViewersScope() {
        let root = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = root
        window.makeKeyAndVisible()
        windows.append(window)
        root.present(viewerNav(), animated: false)
        XCTAssertNotNil(root.presentedViewController)
        XCTAssertEqual(starts, 1)
        DocumentViewers.tearDown(presentedBy: root)
        XCTAssertEqual(stops, 1)
        DocumentViewers.tearDown(presentedBy: root)
        XCTAssertEqual(stops, 1)
    }
}
