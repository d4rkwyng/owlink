import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Review 0.3.0 M1: which answers about a script get the "never safe"
/// rewrite, and how much of them. M2: an empty final answer still goes
/// through the same guard.
@Suite struct OwlSafeGuardScopeTests {
    /// Streams `text` and answers it (or, with `endInToolCall`, ends the
    /// round with a tool call and no answer).
    struct Says: OwlChatEngine {
        let text: String
        var endInToolCall = false
        var title: String { "says" }
        var scoreKey: String { "says" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            for c in text { onText(String(c)) }
            return endInToolCall ? .toolCalls([OwlToolCall(name: "get_lines")]) : .answer(text)
        }
    }

    static func request(_ question: String, language: String = "python", action: OwlQuickAction? = nil,
                        scanHasHigh: Bool = false) -> OwlChatRequest {
        // 15 lines, so the answers' "line 12" and "Line 4" are lines the
        // model was shown (citations of unsent lines are filtered, 0.5.3).
        let text = "import queue\nq = queue.Queue()\n" + String(repeating: "# filler\n", count: 13)
        let snap = OwlDocumentSnapshot(text: text, generation: 1, fileName: "worker.py", language: language)
        let ctx = OwlChatContext.build(snap, scope: .wholeDocument, budget: 6000)!
        return OwlChatRequest(question: question, action: action, context: ctx, snapshot: snap, useTools: false, prose: false,
                              scanHasHigh: scanHasHigh)
    }

    @Test func theGuardDependsOnWhatIsAsked() {
        #expect(Self.request("Is this queue thread safe?").safeClaimGuard == .runClaims)
        #expect(Self.request("What does line 2 do?").safeClaimGuard == .runClaims)
        #expect(Self.request("Is this safe to run?").safeClaimGuard == .verdict)
        #expect(Self.request("Should I run this?").safeClaimGuard == .verdict)
        #expect(Self.request("Check this script for risks.", action: .scriptSafety).safeClaimGuard == .verdict)
        #expect(Self.request("Explain.", action: .explain).safeClaimGuard == .runClaims)
        #expect(Self.request("Is this safe to run?", language: "swift").safeClaimGuard == nil)
    }

    @Test func aThreadSafetyAnswerIsNotRewritten() async throws {
        let answer = "Yes, `queue.Queue` is thread safe; the lock on line 12 is redundant."
        for q in ["Is this queue thread safe?", "Is the queue type-safe?", "Why use queue.Queue here?"] {
            let out = try await OwlChatRunner.run(Self.request(q), engine: Says(text: answer)) { _ in }
            #expect(out.answer == answer, "\(q): \(out.answer)")
        }
        let quoting = "Line 4 quotes \"$f\".\nQuoting \"$f\" keeps it safe with spaces."
        let out = try await OwlChatRunner.run(Self.request("Why the quotes?", language: "shell"), engine: Says(text: quoting)) { _ in }
        #expect(out.answer == quoting)
    }

    @Test func aRunClaimIsStillRewrittenWhateverTheQuestion() async throws {
        let answer = "It builds a queue. This script is safe to run."
        let out = try await OwlChatRunner.run(Self.request("Summarise it."), engine: Says(text: answer)) { _ in }
        #expect(out.answer == "It builds a queue. " + ScriptVerdict.noRedFlags + ".")
        // A run-safety question: the strict verdict rules.
        let v = try await OwlChatRunner.run(Self.request("Is it safe to run?"), engine: Says(text: "Yes.\nIt's safe.")) { _ in }
        #expect(v.answer == "Yes.\n" + ScriptVerdict.noRedFlags + ".")
    }

    // MARK: M2

    @Test func anEmptyFinalAnswerIsTheGuardedStream() async throws {
        // The last round ends in a tool call with no tools offered: no answer, only what streamed.
        let engine = Says(text: "This script is safe to run.", endInToolCall: true)
        let out = try await OwlChatRunner.run(Self.request("Is it safe to run?"), engine: engine) { _ in }
        #expect(!out.answer.isEmpty)
        #expect(out.answer.range(of: "safe", options: .caseInsensitive) == nil, "\(out.answer)")
        // The script check with a high finding: the forced verdict is kept.
        let check = Self.request("Check this script for risks.", language: "shell", action: .scriptSafety, scanHasHigh: true)
        let forced = try await OwlChatRunner.run(check, engine: engine) { _ in }
        #expect(forced.answer.hasSuffix("Verdict: " + ScriptVerdict.forcedDontRun + "."), "\(forced.answer)")
        #expect(forced.answer.range(of: "safe to run", options: .caseInsensitive) == nil)
        // Only "<think>": the thinking is not the answer.
        let think = Says(text: "<think>It is safe to run.</think>", endInToolCall: true)
        let t = try await OwlChatRunner.run(check, engine: think) { _ in }
        #expect(t.answer.range(of: "safe to run", options: .caseInsensitive) == nil, "\(t.answer)")
    }

    @Test func theStoredTextIsNeverTheRawStreamOfAGuardedAnswer() {
        let raw = "Line 2 prints.\nThis script is safe to run."
        #expect(OwlChatRunner.storedText(answer: "", streamed: raw, guard: .verdict, forced: nil)
                == "Line 2 prints.\n" + ScriptVerdict.noRedFlags + ".")
        #expect(OwlChatRunner.storedText(answer: "", streamed: raw, guard: .verdict, forced: .highFinding)
                .hasSuffix("Verdict: " + ScriptVerdict.forcedDontRun + "."))
        #expect(OwlChatRunner.storedText(answer: "", streamed: raw, guard: .runClaims, forced: nil)
                == "Line 2 prints.\n" + ScriptVerdict.noRedFlags + ".")
        // Not a script: as streamed. A real answer: as given.
        #expect(OwlChatRunner.storedText(answer: "", streamed: raw, guard: nil, forced: nil) == raw)
        #expect(OwlChatRunner.storedText(answer: "Done.", streamed: raw, guard: .verdict, forced: nil) == "Done.")
    }
}
