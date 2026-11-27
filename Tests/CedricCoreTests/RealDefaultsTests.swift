import Foundation
import Testing
@testable import CedricCore

/// The one test that still uses a real Foundation suite (Astra review,
/// 0.6): the other tests get `TestDefaults`' in-memory store, which can't
/// show whether reopening a suite reads back what was set and cleared.
/// Its own name in TMPDIR/cedric-test-prefs (a test.sh prefix); the domain
/// and its plist are removed afterwards.
@MainActor
@Suite(.serialized) struct RealDefaultsTests {
    @Test func aReopenedSuiteReadsBackASetAndAClearedValue() throws {
        let name = TestDefaults.name("cedric-owl-test-")
        defer {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(atPath: name + ".plist")
        }
        let first = try #require(UserDefaults(suiteName: name))
        #expect(!(first is InMemoryDefaults), "a real suite")
        OwlCoordinator(registry: OwlProviderRegistry(), defaults: first).neverShowAgain("a")
        // Reopened (the next launch): the saved value is there.
        let reopened = try #require(UserDefaults(suiteName: name))
        let again = OwlCoordinator(registry: OwlProviderRegistry(), defaults: reopened)
        #expect(again.never == ["a"])
        again.resetNeverShown()
        // Reopened after clearing: nothing reads back.
        let cleared = try #require(UserDefaults(suiteName: name))
        #expect(cleared.stringArray(forKey: OwlCoordinator.neverKey) == nil)
        #expect(OwlCoordinator(registry: OwlProviderRegistry(), defaults: cleared).never.isEmpty)
    }
}
