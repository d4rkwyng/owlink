import Foundation
import Testing
@testable import CedricCore

/// The Settings checks open Settings › Cedric only with their own AI
/// defaults suite and models folder (Sol review, settings-compact round 1).
@Suite struct CheckIsolationTests {
    let root: URL
    let home: URL
    let models: URL
    let standard: Set<String> = ["app.owlink.test", "Cedric", "NSGlobalDomain"]

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("check-isolation-\(UUID().uuidString)", isDirectory: true)
        home = root.appendingPathComponent("home", isDirectory: true)
        models = root.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: home.appendingPathComponent("Library/Application Support/Cedric/Models"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    }

    func problem(_ env: [String: String]) -> String? {
        CheckIsolation.problem(env, home: home.path, standardDomains: standard)
    }

    @Test func isolatedRunPasses() {
        #expect(problem(["CEDRIC_AI_DEFAULTS": "cedric-check-suite", "CEDRIC_MODELS_DIR": models.path]) == nil)
    }

    @Test func needsItsOwnSuite() {
        #expect(problem(["CEDRIC_MODELS_DIR": models.path])?.contains("CEDRIC_AI_DEFAULTS is not set") == true)
        #expect(problem(["CEDRIC_AI_DEFAULTS": "", "CEDRIC_MODELS_DIR": models.path])?.contains("not set") == true)
        for suite in standard {
            #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": models.path])?.contains("standard defaults domain") == true)
        }
    }

    @Test func needsItsOwnModelsFolder() throws {
        let suite = "cedric-check-suite"
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite])?.contains("CEDRIC_MODELS_DIR is not set") == true)
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": "models"])?.contains("not an absolute path") == true)
        let missing = root.appendingPathComponent("missing").path
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": missing])?.contains("not an existing folder") == true)
        let real = home.appendingPathComponent("Library/Application Support/Cedric/Models").path
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": real])?.contains("inside ~/Library") == true)
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": home.appendingPathComponent("Library").path])?.contains("inside ~/Library") == true)
        // Through a symbolic link or "..", still the real folder.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: real))
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": link.path])?.contains("inside ~/Library") == true)
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": models.path + "/../home/Library/Application Support/Cedric/Models"])?
            .contains("inside ~/Library") == true)
    }
}
