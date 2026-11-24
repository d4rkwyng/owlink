import XCTest
import UIKit
import CedricCore

/// Settings › "Reopen files from last session" and the stored last document.
@MainActor
final class LastOpenDocumentTests: XCTestCase {
    private var suites: [String] = []
    private var files: [URL] = []

    override func tearDown() async throws {
        for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        suites = []
        for url in files { try? FileManager.default.removeItem(at: url) }
        files = []
    }

    private func defaults() -> UserDefaults {
        let suite = "last-open-tests-\(UUID().uuidString)"
        suites.append(suite)
        return UserDefaults(suiteName: suite)!
    }

    private func tempFile(_ text: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("last-open-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        files.append(dir)
        let url = dir.appendingPathComponent("notes.md")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: Setting

    func testUnsetSettingReopensAndExplicitValuesWin() {
        let d = defaults()
        XCTAssertNil(d.object(forKey: AppSettings.Key.reopenFilesFromLastSession))
        XCTAssertTrue(AppSettings.reopenFilesFromLastSession(in: d))
        XCTAssertTrue(SessionReopenPolicy.shouldReopen(explicit: nil))
        d.set(false, forKey: AppSettings.Key.reopenFilesFromLastSession)
        XCTAssertFalse(AppSettings.reopenFilesFromLastSession(in: d))
        d.set(true, forKey: AppSettings.Key.reopenFilesFromLastSession)
        XCTAssertTrue(AppSettings.reopenFilesFromLastSession(in: d))
    }

    func testKeyIsSharedWithTheMac() {
        XCTAssertEqual(AppSettings.Key.reopenFilesFromLastSession, "reopenFilesFromLastSession")
        XCTAssertEqual(AppSettings.Key.reopenFilesFromLastSession, SessionReopenPolicy.key)
    }

    /// A launch argument (`-reopenFilesFromLastSession NO`) arrives as a
    /// string: it counts, as on the Mac (ccdb2d8). Before, `as? Bool` read
    /// it as unset, so reopen stayed on.
    func testLaunchArgumentStringsCount() {
        let d = defaults()
        d.set("NO", forKey: AppSettings.Key.reopenFilesFromLastSession)
        XCTAssertFalse(AppSettings.reopenFilesFromLastSession(in: d))
        d.set("YES", forKey: AppSettings.Key.reopenFilesFromLastSession)
        XCTAssertTrue(AppSettings.reopenFilesFromLastSession(in: d))
        d.removeObject(forKey: AppSettings.Key.reopenFilesFromLastSession)
        XCTAssertTrue(AppSettings.reopenFilesFromLastSession(in: d), "unset: on")
    }

    // MARK: Store

    func testRememberedFileResolvesAndReads() throws {
        let store = LastOpenDocument(defaults: defaults())
        let url = try tempFile("# Draft")
        store.remember(url)
        let resolved = try XCTUnwrap(store.resolve())
        XCTAssertEqual(resolved.standardizedFileURL.resolvingSymlinksInPath().path,
                       url.standardizedFileURL.resolvingSymlinksInPath().path)
        XCTAssertEqual(try String(contentsOf: resolved, encoding: .utf8), "# Draft")
        XCTAssertNotNil(store.storedPath, "resolving keeps the record")
    }

    func testDeletedFileResolvesToNilAndIsForgotten() throws {
        let d = defaults()
        let store = LastOpenDocument(defaults: d)
        let url = try tempFile("gone soon")
        store.remember(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(store.resolve())
        XCTAssertNil(store.storedPath)
        XCTAssertNil(d.object(forKey: LastOpenDocument.bookmarkKey))
    }

    func testEmptyOrClearedStoreResolvesToNil() throws {
        let store = LastOpenDocument(defaults: defaults())
        XCTAssertNil(store.resolve())
        store.remember(try tempFile("x"))
        store.forget()
        XCTAssertNil(store.resolve())
    }

    /// A clean close forgets its own document only; a crash or a window
    /// going away calls nothing, so the record stays.
    func testCleanCloseForgetsOnlyThatDocument() throws {
        let store = LastOpenDocument(defaults: defaults())
        let a = try tempFile("a"), b = try tempFile("b")
        store.remember(a)
        store.remember(b)
        store.forget(a)
        XCTAssertNotNil(store.resolve(), "closing another window's document keeps the last one")
        store.forget(b)
        XCTAssertNil(store.resolve())
    }

    // MARK: Launch

    func testExplicitOpenAtLaunchWinsOverReopen() {
        XCTAssertFalse(LastOpenDocument.shouldReopenAtLaunch(openingExplicitFile: true, reopenSetting: true))
        XCTAssertFalse(LastOpenDocument.shouldReopenAtLaunch(openingExplicitFile: true, reopenSetting: false))
        XCTAssertFalse(LastOpenDocument.shouldReopenAtLaunch(openingExplicitFile: false, reopenSetting: false))
        XCTAssertTrue(LastOpenDocument.shouldReopenAtLaunch(openingExplicitFile: false, reopenSetting: true))
    }

    /// The first window decides for the whole launch: a file opened
    /// explicitly means no later window reopens the last document.
    func testFirstWindowDecidesOnceForTheLaunch() {
        var explicitFirst = LaunchReopenGate()
        XCTAssertFalse(explicitFirst.consider(openingExplicitFile: true, reopenSetting: true))
        XCTAssertTrue(explicitFirst.considered)
        XCTAssertFalse(explicitFirst.consider(openingExplicitFile: false, reopenSetting: true),
                       "a later window doesn't reopen")

        var reopenFirst = LaunchReopenGate()
        XCTAssertTrue(reopenFirst.consider(openingExplicitFile: false, reopenSetting: true))
        XCTAssertFalse(reopenFirst.consider(openingExplicitFile: false, reopenSetting: true),
                       "only once per launch")

        var settingOff = LaunchReopenGate()
        XCTAssertFalse(settingOff.consider(openingExplicitFile: false, reopenSetting: false))
        XCTAssertTrue(settingOff.considered)
    }

    /// Every way a reopen ends lets the launch offer through again.
    func testCancelledReopenStopsHoldingTheOffer() {
        RecoveryOffer.reopenStarted()
        RecoveryOffer.reopenStarted()
        XCTAssertTrue(RecoveryOffer.reopenInFlight)
        RecoveryOffer.reopenCancelled()
        XCTAssertFalse(RecoveryOffer.reopenInFlight)
    }

    // MARK: Security scope

    private final class ScopeLog {
        var starts: [URL] = []
        var stops: [URL] = []
        var grants = true
    }

    private func scopedStore(_ d: UserDefaults, _ log: ScopeLog) -> LastOpenDocument {
        LastOpenDocument(defaults: d,
                         startAccess: { log.starts.append($0); return log.grants },
                         stopAccess: { log.stops.append($0) })
    }

    func testResolvedScopeEndsWhenThatDocumentIsForgotten() throws {
        let log = ScopeLog()
        let store = scopedStore(defaults(), log)
        let a = try tempFile("a"), b = try tempFile("b")
        store.remember(a)
        let resolved = try XCTUnwrap(store.resolve())
        XCTAssertEqual(log.starts, [resolved])
        XCTAssertEqual(store.scopedURL, resolved)
        XCTAssertTrue(log.stops.isEmpty, "kept while the document is open")

        store.forget(b)
        XCTAssertTrue(log.stops.isEmpty, "another window's document leaves it")
        store.forget(a)
        XCTAssertEqual(log.stops, [resolved], "stopped on the URL that started it")
        XCTAssertNil(store.scopedURL)
        store.forget(a)
        XCTAssertEqual(log.stops.count, 1, "stopped once")
    }

    func testResolvingAgainEndsTheEarlierScope() throws {
        let log = ScopeLog()
        let store = scopedStore(defaults(), log)
        store.remember(try tempFile("a"))
        let first = try XCTUnwrap(store.resolve())
        let second = try XCTUnwrap(store.resolve())
        XCTAssertEqual(log.stops, [first])
        XCTAssertEqual(store.scopedURL, second)
    }

    func testMissingFileEndsTheScopeItStarted() throws {
        let log = ScopeLog()
        let store = scopedStore(defaults(), log)
        let url = try tempFile("gone")
        store.remember(url)
        try FileManager.default.removeItem(at: url)
        XCTAssertNil(store.resolve())
        // A bookmark to a deleted file may not resolve at all (no scope);
        // any scope that was started is stopped.
        XCTAssertEqual(log.stops, log.starts)
        XCTAssertNil(store.scopedURL)
    }

    /// No scope started (denied, or resolved by path): nothing to stop.
    func testUnstartedScopeIsNeverStopped() throws {
        let log = ScopeLog()
        log.grants = false
        let d = defaults()
        let store = scopedStore(d, log)
        let url = try tempFile("x")
        store.remember(url)
        XCTAssertNotNil(store.resolve())
        XCTAssertNil(store.scopedURL)
        store.forget(url)
        XCTAssertTrue(log.stops.isEmpty)

        log.grants = true
        store.remember(url)
        d.removeObject(forKey: LastOpenDocument.bookmarkKey)
        XCTAssertNotNil(store.resolve(), "found by path")
        XCTAssertTrue(log.starts.count == 1, "the path fallback starts no scope")
        store.forget(url)
        XCTAssertTrue(log.stops.isEmpty)
    }
}
