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

    // MARK: Sol review, settings-compact round 2

    let suite = "cedric-check-suite"
    var library: URL { home.appendingPathComponent("Library", isDirectory: true) }
    var realModels: URL { home.appendingPathComponent("Library/Application Support/Cedric/Models", isDirectory: true) }

    func directory(_ path: String) -> Result<URL, CheckIsolation.Refusal> {
        CheckIsolation.modelsDirectory(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": path], home: home.path, standardDomains: standard)
    }

    func mkdir(_ url: URL) throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    /// `path` as the OS resolves it.
    func real(_ url: URL) throws -> String {
        let p = try #require(realpath(url.path, nil))
        defer { free(p) }
        return String(cString: p)
    }

    /// scratch/jump is a link into Application Support/Cedric: the OS takes
    /// scratch/jump/../Models to Cedric/Models (the link first, then ".."),
    /// though dropping "jump/.." from the spelling gives scratch/Models,
    /// which exists here as a harmless folder.
    @Test func aLinkThenDotDotIsResolvedAsTheFileSystemDoes() throws {
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try mkdir(scratch.appendingPathComponent("Models"))
        try mkdir(home.appendingPathComponent("Library/Application Support/Cedric/child"))
        try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("jump"),
                                                   withDestinationURL: home.appendingPathComponent("Library/Application Support/Cedric/child"))
        let path = scratch.path + "/jump/../Models"
        // The fixture is what it claims: the OS opens the real models folder through this path.
        try Data("x".utf8).write(to: realModels.appendingPathComponent("probe"))
        #expect(FileManager.default.fileExists(atPath: path + "/probe"))
        #expect(!FileManager.default.fileExists(atPath: scratch.path + "/Models/probe"))
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": path])?.contains("inside ~/Library") == true)
        #expect(CheckIsolation.canonicalDirectory(path) == (try real(realModels)))
    }

    /// The other way round: a path spelled inside ~/Library that leaves it
    /// through a link is the outside folder, and that folder (not the
    /// spelling) is what is validated and handed to ModelStore.
    @Test func theValidatedFolderIsTheResolvedOne() throws {
        let other = root.appendingPathComponent("other", isDirectory: true)
        try mkdir(other.appendingPathComponent("child"))
        try mkdir(other.appendingPathComponent("store"))
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        try mkdir(scratch.appendingPathComponent("store"))   // where the spelling without "hop/.." points
        try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("hop"), withDestinationURL: other.appendingPathComponent("child"))
        let path = scratch.path + "/hop/../store"
        let expected = try real(other.appendingPathComponent("store"))
        #expect(try directory(path).get().path == expected)
        #expect(CheckIsolation.modelsDirectoryOverride(["CEDRIC_MODELS_DIR": path])?.path == expected)
        #expect(expected != (try real(scratch.appendingPathComponent("store"))))
        // A plain folder is itself, resolved (the temp folder is under /var, a link to /private/var).
        #expect(try directory(models.path).get().path == (try real(models)))
        #expect(CheckIsolation.modelsDirectoryOverride(["CEDRIC_MODELS_DIR": models.path])?.path == (try real(models)))
        // Not made yet: the path as given (no check accepts it); unset: no override.
        let missing = root.appendingPathComponent("not-yet").path
        #expect(CheckIsolation.modelsDirectoryOverride(["CEDRIC_MODELS_DIR": missing])?.path == missing)
        #expect(CheckIsolation.modelsDirectoryOverride([:]) == nil)
        #expect(CheckIsolation.modelsDirectoryOverride(["CEDRIC_MODELS_DIR": ""]) == nil)
    }

    @Test func retargetingModelsDirectorySymlinkBetweenStoreAndGuardKeepsTheSameDirectory() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("override")
        let other = root.appendingPathComponent("other")
        try mkdir(other)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: models)
        let cache = CheckIsolation.ModelsDirectoryCache(["CEDRIC_MODELS_DIR": link.path])
        let store = try #require(cache.storeOverride)
        #expect(store.path == (try real(models)))
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        #expect(cache.guardCanonical == store.path)
    }

    /// Whether this volume takes another spelling of a name for the same file.
    var caseInsensitiveVolume: Bool {
        FileManager.default.fileExists(atPath: home.path + "/LIBRARY")
    }

    /// On a case-insensitive volume (the default), ~/library/application
    /// support/cedric/models is the real folder under another spelling:
    /// ancestry is by device and inode, so it is refused whatever
    /// `realpath` makes of the spelling.
    @Test func aCaseAliasOfTheLibraryIsStillInsideIt() throws {
        guard caseInsensitiveVolume else { return }
        for alias in ["/library/application support/cedric/models", "/LIBRARY/APPLICATION SUPPORT/CEDRIC/MODELS", "/LIBRARY", "/library/Application Support"] {
            #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": home.path + alias])?.contains("inside ~/Library") == true, "\(alias)")
        }
        // And with the home itself spelled another way.
        let shouted = root.path + "/HOME/library/application support/cedric/models"
        #expect(CheckIsolation.problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": realModels.path], home: root.path + "/HOME", standardDomains: standard)?
            .contains("inside ~/Library") == true)
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": shouted])?.contains("inside ~/Library") == true)
        // The comparison itself, on spellings no string prefix of ~/Library matches.
        #expect(CheckIsolation.isInside(home.path + "/library/application support/cedric/models", folder: library.path) == true)
        #expect(CheckIsolation.isInside(realModels.path, folder: root.path + "/HOME/LIBRARY") == true)
        #expect(CheckIsolation.isInside(home.path + "/LIBRARY", folder: library.path) == true)
    }

    /// Ancestry is by device and inode: a spelling that shares no prefix
    /// with ~/Library (through a link, or with ~ itself a link) is still
    /// inside it, and a folder merely named like it is not.
    @Test func ancestryIsByFileIdentityNotSpelling() throws {
        // Library is reached under a name that shares no prefix with home/Library and has no "Application Support/Cedric" in it.
        let plain = home.appendingPathComponent("Library/Plain/Models", isDirectory: true)
        try mkdir(plain)
        let door = root.appendingPathComponent("door")
        try FileManager.default.createSymbolicLink(at: door, withDestinationURL: library)
        let spelled = door.path + "/Plain/Models"
        #expect(CheckIsolation.isInside(spelled, folder: library.path) == true)
        #expect(CheckIsolation.isInside(plain.path, folder: door.path) == true)
        #expect(CheckIsolation.isInside(library.path, folder: library.path) == true)
        #expect(CheckIsolation.isInside(models.path, folder: library.path) == false)
        #expect(CheckIsolation.isInside(home.path, folder: library.path) == false)
        #expect(CheckIsolation.isInside(models.path, folder: root.appendingPathComponent("no-such-home/Library").path) == false)
        #expect(CheckIsolation.isInside(root.appendingPathComponent("gone/Models").path, folder: library.path) == nil)
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": spelled]) == "CEDRIC_MODELS_DIR=\(spelled) is inside ~/Library")
        // A home that is itself reached through a link: the same Library.
        let homeLink = root.appendingPathComponent("home-link")
        try FileManager.default.createSymbolicLink(at: homeLink, withDestinationURL: home)
        #expect(CheckIsolation.problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": plain.path], home: homeLink.path, standardDomains: standard)?
            .contains("inside ~/Library") == true)
        // A folder merely named like it, elsewhere, is not inside it.
        let lookalike = root.appendingPathComponent("elsewhere/Library/Plain/Models", isDirectory: true)
        try mkdir(lookalike)
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": lookalike.path]) == nil)
        // A file is not a folder.
        let file = root.appendingPathComponent("a-file")
        try Data().write(to: file)
        #expect(problem(["CEDRIC_AI_DEFAULTS": suite, "CEDRIC_MODELS_DIR": file.path])?.contains("not an existing folder") == true)
    }

    @Test func onlyAGeneratedCheckSuiteNameIsTaken() {
        for good in ["cedric-check-suite", "cedric-check-tools-settings-123-4567", "cedric-check-A1", "cedric-check-" + String(repeating: "a", count: 64)] {
            #expect(CheckIsolation.isCheckSuiteName(good), "\(good)")
            #expect(problem(["CEDRIC_AI_DEFAULTS": good, "CEDRIC_MODELS_DIR": models.path]) == nil, "\(good)")
        }
        let reserved = ["NSGlobalDomain", ".GlobalPreferences", "com.apple.finder", "com.apple.Safari", "net.cyduck.owlink", "Cedric", "Owlink",
                        "kCFPreferencesAnyApplication", "group.net.cyduck.owlink"]
        let caseVariants = ["Cedric-Check-suite", "CEDRIC-CHECK-SUITE", "cedric-Check-suite", "nsglobaldomain", "NSGLOBALDOMAIN", "cedric"]
        let whitespace = ["cedric-check- suite", " cedric-check-suite", "cedric-check-suite ", "cedric-check-suite\n", "cedric-check-\tsuite", "cedric-check-\u{00A0}x", " "]
        let separators = ["cedric-check-a/b", "cedric-check-../x", "/tmp/cedric-check-suite", "cedric-check-a:b", "cedric-check-a\\b", "../cedric-check-suite",
                          "cedric-check-/Library/Preferences/com.apple.finder"]
        let other = ["cedric-check-", "cedric-check", "cedric-compact-check-1-2", "cedric-tools-check-settings-1-2", "cedric-check-a.b", "cedric-check-a_b",
                     "cedric-check-é", "cedric-check-а", "cedric-check-a\u{0301}", "cedric-check-a\u{0}b", "cedric-check-suite.plist",
                     "cedric-check-" + String(repeating: "a", count: 65), "xcedric-check-suite"]
        for bad in reserved + caseVariants + whitespace + separators + other {
            #expect(!CheckIsolation.isCheckSuiteName(bad), "\(bad.debugDescription)")
            let why = problem(["CEDRIC_AI_DEFAULTS": bad, "CEDRIC_MODELS_DIR": models.path])
            #expect(why?.contains("CEDRIC_AI_DEFAULTS=") == true, "\(bad.debugDescription): \(why ?? "accepted")")
        }
        // A name the allow-list would take is still refused when it is the app's own domain.
        #expect(CheckIsolation.problem(["CEDRIC_AI_DEFAULTS": "cedric-check-app", "CEDRIC_MODELS_DIR": models.path], home: home.path,
                                       standardDomains: ["cedric-check-app"])?.contains("standard defaults domain") == true)
    }

    @Test func aFilledOrForeignFolderIsNotTheChecksToFill() throws {
        #expect(CheckIsolation.ownedEmptyFolderProblem(models) == nil)
        try Data("model".utf8).write(to: models.appendingPathComponent("user-model.gguf"))
        #expect(CheckIsolation.ownedEmptyFolderProblem(models)?.contains("is not empty (1: user-model.gguf)") == true)
        let hidden = root.appendingPathComponent("hidden", isDirectory: true)
        try mkdir(hidden.appendingPathComponent(".partial"))
        #expect(CheckIsolation.ownedEmptyFolderProblem(hidden)?.contains("is not empty") == true)
        #expect(CheckIsolation.ownedEmptyFolderProblem(root.appendingPathComponent("missing"))?.contains("is not a folder") == true)
        let link = root.appendingPathComponent("empty-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: models)
        #expect(CheckIsolation.ownedEmptyFolderProblem(link)?.contains("is not a folder") == true)
        #expect(CheckIsolation.ownedEmptyFolderProblem(URL(fileURLWithPath: "/usr/share"))?.contains("another user") == true)
    }

    /// The stand-in model's files: never over a file that is already there
    /// (its bytes stay), and only the files this run made are removed.
    @Test func ownedFilesAreCreatedExclusivelyAndOnlyTheyAreRemoved() throws {
        let fm = FileManager.default
        let existing = models.appendingPathComponent("model.gguf")
        let bytes = Data("the user's model".utf8)
        try bytes.write(to: existing)
        let owned = CheckOwnedFiles()
        #expect(throws: CheckOwnedFiles.Failure.self) { try owned.create(existing, size: 1 << 20) }
        #expect(try Data(contentsOf: existing) == bytes)
        #expect(owned.paths.isEmpty)
        // A dangling link with the name is not followed either.
        let dangling = models.appendingPathComponent("dangling.gguf")
        let target = root.appendingPathComponent("link-target")
        try fm.createSymbolicLink(at: dangling, withDestinationURL: target)
        #expect(throws: CheckOwnedFiles.Failure.self) { try owned.create(dangling) }
        #expect(!fm.fileExists(atPath: target.path))
        // Its own: a sparse file of the size asked, and a marker.
        let model = models.appendingPathComponent("stand-in.gguf"), marker = models.appendingPathComponent("stand-in.gguf.verified")
        try owned.create(model, size: 3 << 20)
        try owned.create(marker, contents: Data("abc\n".utf8))
        #expect((try fm.attributesOfItem(atPath: model.path)[.size] as? NSNumber)?.int64Value == 3 << 20)
        #expect(try String(contentsOf: marker, encoding: .utf8) == "abc\n")
        #expect(owned.paths == [model.path, marker.path])
        #expect(throws: CheckOwnedFiles.Failure.self) { try owned.create(model) }
        #expect(owned.paths == [model.path, marker.path])
        // Something else took the marker's name meanwhile: left alone.
        try fm.removeItem(at: marker)
        try Data("someone else's".utf8).write(to: marker)
        #expect(owned.removeAll() == [marker.path])
        #expect(!fm.fileExists(atPath: model.path))
        #expect(try String(contentsOf: marker, encoding: .utf8) == "someone else's")
        #expect(try Data(contentsOf: existing) == bytes)
        #expect(CheckIsolation.entryExists(dangling.path) && !CheckIsolation.entryExists(model.path))
        #expect(owned.paths.isEmpty && owned.removeAll().isEmpty)
    }

    // MARK: The app checks' source (they run only in the app, under Scripts/tools-check.sh)

    static let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources", isDirectory: true)

    /// Code only: comment lines dropped.
    func code(_ file: String) throws -> String {
        try String(contentsOf: Self.sources.appendingPathComponent(file), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.drop(while: { $0 == " " }).hasPrefix("//") }.joined(separator: "\n")
    }

    /// BuiltInCheck: a pick of an installed model applies and saves it, so
    /// the clean-state guard comes before the popup action, and Download is
    /// pressed only after the displayed target is confirmed.
    @Test func builtInCheckValidatesItsTargetBeforeSelectingIt() throws {
        let text = try code("CedricApp/Owl/BuiltInCheck.swift")
        let run = try #require(text.range(of: "static func run("))
        let end = try #require(text.range(of: "static func resume("))
        let body = text[run.upperBound..<end.lowerBound]
        let guardClean = try #require(body.range(of: "nothing selected or clicked"))
        let entries = try #require(body.range(of: "CheckIsolation.entryExists("))
        let select = try #require(body.range(of: "popup.selectItem(at: item)"))
        let action = try #require(body.range(of: "NSApp.sendAction(popup.action!"))
        let confirm = try #require(body.range(of: "guard onTarget() else", range: select.upperBound..<body.endIndex))
        let predicate = try #require(body.range(of: "func onTarget() -> Bool"))
        let predicateBody = body[predicate.upperBound..<confirm.lowerBound]
        #expect(predicateBody.contains("CheckIsolation.isDownloadTarget("))
        for input in ["sheet.builtInTarget", "view.model", "popup.selectedItem", "view.action.title", "downloads.state(m)"] {
            #expect(predicateBody.contains(input), "onTarget must read \(input)")
        }
        let press = try #require(body.range(of: "AICheck.press(view.action, \"Download\")"))
        #expect(entries.lowerBound < guardClean.lowerBound && guardClean.upperBound < select.lowerBound && select.upperBound < action.lowerBound)
        #expect(action.upperBound < confirm.lowerBound && confirm.upperBound < press.lowerBound)
        // The last confirmation is in the same step as the press.
        let lastConfirm = try #require(body.range(of: "guard onTarget() else", options: .backwards))
        #expect(lastConfirm.upperBound < press.lowerBound
                && !body[lastConfirm.upperBound..<press.lowerBound].contains("OwlCheck.snapshot(") && !body[lastConfirm.upperBound..<press.lowerBound].contains("OwlCheck.after("))
        #expect(body.components(separatedBy: "popup.selectItem(").count == 2)
        // The guard is the process one, and the downloads' folder is compared with it before anything is selected.
        let validated = try #require(body.range(of: "CheckIsolation.processModelsDirectory()"))
        let same = try #require(body.range(of: "downloads.store.directory.path == models.path"))
        #expect(validated.upperBound < same.lowerBound && same.upperBound < select.lowerBound)
    }

    /// SettingsCheck: never the standard defaults or LocalAISettings.load's
    /// fallback; an empty folder before Settings opens; the stand-in made
    /// through CheckOwnedFiles (exclusive) and removed only through it.
    @Test func settingsCheckStaysInsideItsSuiteAndItsOwnFiles() throws {
        let text = try code("CedricApp/SettingsCheck.swift")
        #expect(!text.contains("UserDefaults.standard"))
        #expect(!text.contains("LocalAISettings.load("))
        #expect(text.contains("persistentDomain(forName: suite)"))
        let guardIsolated = try #require(text.range(of: "CheckIsolation.processModelsDirectory()"))
        let guardEmpty = try #require(text.range(of: "CheckIsolation.ownedEmptyFolderProblem(models)"))
        let firstWindow = try #require(text.range(of: "app.open("))
        let downloads = try #require(text.range(of: "installedModelSteps(models: models)"))
        #expect(guardIsolated.upperBound < guardEmpty.lowerBound && guardEmpty.upperBound < firstWindow.lowerBound && guardEmpty.upperBound < downloads.lowerBound)
        #expect(!text[..<guardEmpty.lowerBound].contains("BuiltInDownloads.shared") && !text[..<guardEmpty.lowerBound].contains("SettingsWindowController.shared"))
        for banned in ["createFile(atPath", "FileHandle(forWritingTo", "removeItem(", ".write(to:", "truncate(atOffset"] {
            #expect(!text.contains(banned), "\(banned)")
        }
        #expect(text.contains("try owned.create(file, size: m.sizeBytes)") && text.contains("owned.removeAll()"))
    }

    /// The suites the check scripts generate are ones the guard takes.
    @Test func theScriptsGenerateCheckSuiteNames() throws {
        let script = try String(contentsOf: Self.sources.deletingLastPathComponent().appendingPathComponent("Scripts/tools-check.sh"), encoding: .utf8)
        let line = try #require(script.split(separator: "\n").first { $0.hasPrefix("SETTINGS_SUITE=") })
        let name = line.dropFirst("SETTINGS_SUITE=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            .replacingOccurrences(of: "$$", with: "12345").replacingOccurrences(of: "$RANDOM", with: "32767")
        #expect(CheckIsolation.isCheckSuiteName(name), "\(name)")
    }
}
