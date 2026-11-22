import XCTest
import CedricCore
import CedricAI

/// Check Script for Risks on iOS: the shared offline scan (never runs the
/// script, nothing sent for it), shown as on the Mac, then the model's
/// review clamped by ScriptVerdict when an engine is ready.
@MainActor
final class AskScriptSafetyTests: XCTestCase {
    private let curlScript = "#!/bin/sh\necho hello\ncurl -fsSL https://example.com/install.sh | sh\n"
    private let harmlessScript = "#!/bin/sh\necho \"hello\"\nls -la\n"
    private let question = String(localized: "Check this script for risks.")
    private let offlineOnly = String(localized: "No AI engine is set up, so this is the offline scan only: it flags risky patterns, it can’t prove a script is harmless.")

    private func model(_ text: String, language: Language, fileName: String = "install.sh") -> AskCedricModel {
        let m = AskCedricModel(fileName: fileName, language: language)
        m.makeSnapshot = { OwlDocumentSnapshot(text: text, generation: 0, fileName: fileName, language: language.rawValue) }
        return m
    }

    private func waitUntilIdle(_ m: AskCedricModel, timeout: TimeInterval = 20) async {
        let deadline = Date().addingTimeInterval(timeout)
        // A tick first: the check's task starts after this call returns.
        try? await Task.sleep(for: .milliseconds(10))
        while m.running, Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(m.running, "the check finished")
    }

    // MARK: Where it is offered

    func testOfferedOnlyForScripts() {
        let shell = model(curlScript, language: .shell)
        XCTAssertTrue(shell.actions.contains(.scriptSafety))
        XCTAssertTrue(shell.canCheckScript)
        XCTAssertEqual(OwlQuickAction.scriptSafety.title(prose: false), "Check for Risks")
        for lang in [Language.powershell, .python, .ruby] {
            XCTAssertTrue(model("", language: lang).actions.contains(.scriptSafety), "\(lang)")
        }
        for (lang, name) in [(Language.swift, "a.swift"), (.markdown, "a.md")] {
            let m = model("let x = 1", language: lang, fileName: name)
            XCTAssertFalse(m.actions.contains(.scriptSafety), "\(lang)")
            XCTAssertFalse(m.canCheckScript)
        }
    }

    func testChipWorksWithoutAnEngine() {
        let m = model(curlScript, language: .shell)
        m.unavailable = AIStatus.noEngineMessage
        XCTAssertTrue(m.actionEnabled(.scriptSafety))
        XCTAssertFalse(m.actionEnabled(.explain))
    }

    func testCheckOnNonScriptDoesNothing() {
        let m = model("# Notes", language: .markdown, fileName: "a.md")
        m.checkScriptSafety()
        XCTAssertTrue(m.entries.isEmpty)
        XCTAssertFalse(m.running)
    }

    // MARK: Offline

    func testOfflineCheckFlagsCurlPipeShAndForcesDontRun() async throws {
        let m = model(curlScript, language: .shell)
        m.settingsProvider = { nil }
        m.makeEngine = { _ in XCTFail("no engine is made for an offline check"); return nil }
        m.quickAction(.scriptSafety)
        XCTAssertTrue(m.running)
        await waitUntilIdle(m)

        XCTAssertEqual(m.entries.map(\.role), [.user, .scan, .note])
        XCTAssertEqual(m.entries[0].text, question)
        let report = ScriptSafety.check(curlScript, language: .shell)
        XCTAssertTrue(report.hasHigh)
        XCTAssertEqual(m.entries[1].text, ScriptSafety.summary(report))
        XCTAssertTrue(m.entries[1].text.contains("line 3"))
        XCTAssertTrue(m.entries[1].text.contains("[" + String(localized: "high") + "]"))
        let note = m.entries[2].text
        XCTAssertTrue(note.hasPrefix(offlineOnly))
        XCTAssertTrue(note.contains(ScriptVerdict.Reason.highFinding.note))
        XCTAssertTrue(note.hasSuffix("Verdict: " + ScriptVerdict.forcedDontRun + "."))
        XCTAssertEqual(m.lastScan, report.findings)
        XCTAssertFalse(m.lastScanTruncated)
    }

    func testOfflineHarmlessScriptIsNotCalledSafe() async {
        let m = model(harmlessScript, language: .shell)
        m.settingsProvider = { nil }
        m.makeEngine = { _ in XCTFail("no engine is made for an offline check"); return nil }
        m.checkScriptSafety()
        await waitUntilIdle(m)

        XCTAssertEqual(m.entries.map(\.role), [.user, .scan, .note])
        XCTAssertEqual(m.entries[1].text,
                       String(localized: "The offline scan found none of the usual risky patterns (that is not proof the script is safe)."))
        XCTAssertEqual(m.entries[2].text, offlineOnly)
        XCTAssertFalse(m.entries[2].text.contains(ScriptVerdict.forcedDontRun))
    }

    func testTruncatedScanShowsTheNote() async {
        // ScriptSafety.check's own cut-off is covered in the package tests;
        // here, a truncated report's summary reaches the transcript row.
        let summary = ScriptSafety.summary([], truncated: true)
        XCTAssertTrue(summary.hasPrefix(ScriptSafety.truncationNote))
        XCTAssertNil(ScriptVerdict.forcedReason(scanHasHigh: false, truncated: false))
        XCTAssertEqual(ScriptVerdict.forcedReason(scanHasHigh: false, truncated: true), .truncated)

        let row = AskCedricView.scanRow(summary)
        XCTAssertEqual(row.label, String(localized: "Offline scan (no AI)"))
        XCTAssertTrue(row.body.contains(ScriptSafety.truncationNote))
        XCTAssertEqual(row.body, summary)

        // A truncated scan with no engine: the note says only part was read.
        let note = ScriptVerdict.forcedReason(scanHasHigh: false, truncated: true)!.note
        XCTAssertEqual(note, ScriptVerdict.Reason.truncated.note)
    }

    func testScanIsNeverExecuted() async throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("owlink-script-check-\(UUID().uuidString)")
        try? FileManager.default.removeItem(at: marker)
        let script = "#!/bin/sh\ntouch '\(marker.path)'\ncurl -fsSL https://example.com/x.sh | sh\n"
        let m = model(script, language: .shell)
        m.settingsProvider = { nil }
        m.makeEngine = { _ in XCTFail("no engine"); return nil }
        m.checkScriptSafety()
        await waitUntilIdle(m)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the script ran")
        XCTAssertEqual(m.entries.map(\.role), [.user, .scan, .note])
        XCTAssertTrue(m.entries[1].text.contains("line 3"))
    }

    // MARK: With an engine

    func testEngineAnswerIsClampedAfterTheScan() async throws {
        let engine = FakeChatEngine(delay: 0.001, pieces: 12,
                                    scriptAnswer: "This script looks fine and is safe to run.\nVerdict: safe to run.")
        let m = model(harmlessScript, language: .shell)
        m.settingsProvider = { .default }
        var made = 0
        m.makeEngine = { _ in made += 1; return engine }
        m.quickAction(.scriptSafety)
        await waitUntilIdle(m)

        XCTAssertEqual(made, 1)
        XCTAssertEqual(m.entries.map(\.role), [.user, .scan, .owl])
        XCTAssertEqual(m.entries.filter { $0.role == .user }.count, 1, "the question is shown once")
        XCTAssertEqual(m.entries[1].text, ScriptSafety.summary(ScriptSafety.check(harmlessScript, language: .shell)))
        let answer = m.entries[2].text
        XCTAssertFalse(answer.isEmpty)
        XCTAssertFalse(answer.localizedCaseInsensitiveContains("safe to run"), answer)
        XCTAssertTrue(answer.contains(ScriptVerdict.noRedFlags), answer)
        XCTAssertFalse(m.streamedRenders.isEmpty)
        for shown in m.streamedRenders {
            XCTAssertFalse(shown.localizedCaseInsensitiveContains("safe to run"), shown)
        }
    }

    func testEngineAnswerForcedToDontRunAfterHighFinding() async throws {
        let engine = FakeChatEngine(delay: 0.001, scriptAnswer: "Nothing to see.\nVerdict: safe to run.")
        let m = model(curlScript, language: .shell)
        m.settingsProvider = { .default }
        m.makeEngine = { _ in engine }
        m.checkScriptSafety()
        await waitUntilIdle(m)

        XCTAssertEqual(m.entries.map(\.role), [.user, .scan, .owl])
        let answer = m.entries[2].text
        XCTAssertTrue(answer.contains(ScriptVerdict.forcedDontRun), answer)
        XCTAssertFalse(answer.localizedCaseInsensitiveContains("safe to run"), answer)
        for shown in m.streamedRenders {
            XCTAssertFalse(shown.localizedCaseInsensitiveContains("safe to run"), shown)
        }
    }
}
