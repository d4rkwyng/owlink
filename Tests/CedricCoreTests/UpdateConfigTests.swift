import Foundation
import Testing
@testable import CedricCore

/// The updater is on only for a release build whose Info.plist names an
/// HTTPS feed, a 32-byte EdDSA public key and a required signed feed.
/// No key is generated here: `notAKey` is 32 bytes of ASCII text, base64,
/// which only has the shape of a public key, and the feed host is under
/// the reserved .invalid TLD.
@Suite struct UpdateConfigTests {
    static let notAKey = Data("owlink-test-only-not-a-real-key!".utf8).base64EncodedString()
    static let feed = "https://updates.example.invalid/owlink/appcast.xml"

    static func plist(feed: Any? = feed, key: Any? = notAKey, signed: Any? = true) -> [String: Any] {
        var d: [String: Any] = ["CFBundleIdentifier": "net.mindtricks.cedric"]
        if let feed { d["SUFeedURL"] = feed }
        if let key { d["SUPublicEDKey"] = key }
        if let signed { d["SURequireSignedFeed"] = signed }
        return d
    }

    @Test func notAKeyHasTheShapeOfAPublicKey() {
        #expect(Data(base64Encoded: Self.notAKey)?.count == 32)
    }

    @Test func emptyPlaceholdersAsBundleAppWritesThemDisableTheUpdater() {
        // Scripts/bundle-app.sh's default: both keys present, both empty.
        let c = UpdateConfig.from(info: Self.plist(feed: "", key: ""), checksEnabled: false)
        #expect(c == .disabled(.notConfigured))
        #expect(!c.isEnabled)
        #expect(c.tooltip?.contains("aren’t set up") == true)
    }

    @Test func eitherOneEmptyOrMissingDisablesIt() {
        for info in [Self.plist(feed: ""), Self.plist(key: ""), Self.plist(feed: nil), Self.plist(key: nil),
                     Self.plist(feed: "   "), Self.plist(key: " \n"), Self.plist(feed: nil, key: nil)] {
            #expect(UpdateConfig.from(info: info, checksEnabled: false) == .disabled(.notConfigured), "\(info)")
        }
        #expect(UpdateConfig.from(info: nil, checksEnabled: false) == .disabled(.notConfigured))
        // Not a string (a hand-edited plist): treated as missing.
        #expect(UpdateConfig.from(info: Self.plist(feed: 42), checksEnabled: false) == .disabled(.notConfigured))
    }

    @Test func httpsOnly() {
        for f in ["http://updates.example.invalid/appcast.xml", "ftp://updates.example.invalid/a.xml",
                  "file:///tmp/appcast.xml", "updates.example.invalid/appcast.xml", "https:///appcast.xml",
                  "https://user:pw@updates.example.invalid/appcast.xml"] {
            #expect(UpdateConfig.from(info: Self.plist(feed: f), checksEnabled: false) == .disabled(.feedNotHTTPS), "\(f)")
        }
        #expect(UpdateConfig.from(info: Self.plist(feed: "HTTPS://updates.example.invalid/a.xml"), checksEnabled: false).isEnabled)
    }

    @Test func theKeyMustBe32BytesOfBase64() {
        let short = Data(repeating: 7, count: 31).base64EncodedString()
        let long = Data(repeating: 7, count: 64).base64EncodedString()
        for k in [short, long, "not base64!", "PUBLIC_KEY_HERE"] {
            #expect(UpdateConfig.from(info: Self.plist(key: k), checksEnabled: false) == .disabled(.badKey), "\(k)")
        }
    }

    @Test func aSignedFeedIsRequired() {
        for s in [nil, false, "YES", 1] as [Any?] {
            #expect(UpdateConfig.from(info: Self.plist(signed: s), checksEnabled: false) == .disabled(.unsignedFeed), "\(String(describing: s))")
        }
    }

    @Test func aCheckBuildNeverUpdates() {
        let c = UpdateConfig.from(info: Self.plist(), checksEnabled: true)
        #expect(c == .disabled(.checkBuild))
        #expect(c.tooltip != nil)
    }

    @Test func configuredReleaseBuildIsEnabled() throws {
        let c = UpdateConfig.from(info: Self.plist(), checksEnabled: false)
        #expect(c == .enabled(feed: try #require(URL(string: Self.feed)), publicKey: Self.notAKey))
        #expect(c.tooltip == nil)
    }

    @Test func everyDisabledReasonHasATooltip() {
        let all: [UpdateConfig.Reason] = [.checkBuild, .notConfigured, .feedNotHTTPS, .badKey, .unsignedFeed, .frameworkMissing]
        for r in all { #expect(UpdateConfig.disabled(r).tooltip?.isEmpty == false, "\(r)") }
    }

    @Test func automaticChecksUseSparklesOwnKey() {
        #expect(UpdateConfig.automaticChecksKey == "SUEnableAutomaticChecks")
    }
}
