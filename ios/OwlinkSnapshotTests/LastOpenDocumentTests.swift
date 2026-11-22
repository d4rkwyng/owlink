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
        XCTAssertTrue(SessionReopenPolicy.shouldReopen(explicit: nil, systemKeepsWindows: nil))
        d.set(false, forKey: AppSettings.Key.reopenFilesFromLastSession)
        XCTAssertFalse(AppSettings.reopenFilesFromLastSession(in: d))
        d.set(true, forKey: AppSettings.Key.reopenFilesFromLastSession)
        XCTAssertTrue(AppSettings.reopenFilesFromLastSession(in: d))
    }

    func testKeyIsSharedWithTheMac() {
        XCTAssertEqual(AppSettings.Key.reopenFilesFromLastSession, "reopenFilesFromLastSession")
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
}
