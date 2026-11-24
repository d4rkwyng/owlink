import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// A new Ask Cedric question cancels the one in flight (Owlink real-use
/// test: a whole-file question abandoned without Stop left the next one on
/// "…" for 11+ minutes at 400% CPU), and nothing the cancelled one still
/// sends reaches the new question's thread.
@MainActor
@Suite struct OwlAskCancelTests {
    static let doc = "a,b,c\n1,2,3\n4,5,6\n7,8,nine\n"

    func request(_ question: String) -> OwlChatRequest {
        let s = OwlDocumentSnapshot(text: Self.doc, generation: 1, fileName: "t.csv", language: "csv")
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        return OwlChatRequest(question: question, context: ctx, snapshot: s, useTools: false, prose: false)
    }

    /// Streams "A-start", then hangs until cancelled (as a long prefill
    /// does), then still tries to send "A-LATE" before it gives up: the
    /// late delivery a stuck "…" came from.
    final class Hanging: OwlChatEngine, @unchecked Sendable {
        let sawCancel = Box(false)
        let started = Box(false)
        var title: String { "Hanging" }
        var scoreKey: String { "hanging" }
        var contextBudget: Int { 6_000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            started.mutate { $0 = true }
            onText("A-start ")
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
            sawCancel.mutate { $0 = true }
            onText("A-LATE")
            throw CancellationError()
        }
    }

    /// The panel's wiring in miniature: what a request sends shows only
    /// while it is current; its answer or error ends it only then.
    @MainActor final class Panel {
        let life = OwlAskLifecycle()
        var transcript: [String] = []
        var answers: [String] = []
        var errors: [String] = []

        func ask(_ req: OwlChatRequest, engine: any OwlChatEngine) {
            transcript.append("You: " + req.question)
            life.start { [self] ticket in
                do {
                    let o = try await OwlChatRunner.run(req, engine: engine) { ev in
                        guard case .text(let t) = ev else { return }
                        Task { @MainActor in if self.life.isCurrent(ticket) { self.transcript.append(t) } }
                    }
                    await Task.yield()
                    guard life.isCurrent(ticket) else { return }
                    answers.append(o.answer)
                    life.finished(ticket)
                } catch {
                    guard life.isCurrent(ticket) else { return }
                    errors.append("\(error)")
                    life.finished(ticket)
                }
            }
        }
    }

    @Test func aSecondQuestionCancelsTheFirst() async throws {
        let panel = Panel()
        let slow = Hanging()
        panel.ask(request("Review the whole file."), engine: slow)
        #expect(await eventually { slow.started.value })
        #expect(panel.life.isRunning)

        // No Stop: the next question is asked straight away.
        panel.ask(request("Which rows look wrong or suspicious?"), engine: FakeChatEngine(delay: 0.001, pieces: 2))
        #expect(panel.life.cancelledCount == 1)
        #expect(await eventually { slow.sawCancel.value }, "the first request's engine call was cancelled")
        #expect(await eventually { @MainActor in panel.answers.count == 1 })
        #expect(!panel.life.isRunning)

        // Give a straggler time to arrive: it must not.
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(!panel.transcript.contains("A-LATE"), "the cancelled answer never reaches the new thread")
        #expect(panel.errors.isEmpty, "the cancelled request's error isn't shown either")
        #expect(panel.answers.first?.contains("A-") == false)
    }

    @Test func cancelAbandonsAtOnceAndFinishedIgnoresAStaleTicket() async {
        let life = OwlAskLifecycle()
        let first = life.start { _ in try? await Task.sleep(nanoseconds: 5_000_000_000) }
        let second = life.start { _ in }
        #expect(!life.isCurrent(first) && life.isCurrent(second))
        life.finished(first)   // a late finish of the cancelled one
        #expect(life.isCurrent(second), "the old request's finish doesn't end the new one")
        life.cancel()
        #expect(!life.isRunning && life.cancelledCount == 2)
    }

    @Test func waitingLabelSaysProcessingPromptWithElapsedTime() {
        let life = OwlAskLifecycle()
        let t0 = Date(timeIntervalSince1970: 1_000)
        life.start(now: t0) { _ in }
        let label = OwlAskWaiting.label(elapsed: life.elapsed(now: t0.addingTimeInterval(12.4)))
        #expect(label == "Processing prompt… 12 s")
        #expect(OwlAskWaiting.label(elapsed: 65) == "Processing prompt… 1:05")
        #expect(OwlAskWaiting.label(elapsed: 3, searching: true) == "Looking through the file… 3 s")
        #expect(OwlAskWaiting.stopTitle(elapsed: 720) == "Stop · 12:00")
        #expect(!label.hasPrefix("…") && label != "...")
    }
}

/// The built-in engine's cancel is per request: a request starting can no
/// longer clear an earlier one's cancel (0.5.2 reset one shared flag on
/// every generate, so a cancelled prefill ran on to its end once the owl
/// or the next question asked).
@Suite struct LlamaCancelTests {
    @Test func aLaterRequestNeverClearsAnEarlierCancel() {
        let context = LlamaLoadStop()
        let a = LlamaRequestStop()
        context.begin(a)
        #expect(!context.shouldAbort)
        a.set()
        #expect(context.shouldAbort, "the abort callback stops A's decode mid-prefill")
        let b = LlamaRequestStop()
        context.begin(b)
        #expect(a.isSet, "B starting leaves A cancelled")
        #expect(!context.shouldAbort, "and B's own decode isn't aborted")
        b.set()
        #expect(context.shouldAbort)
        context.begin(nil)
        #expect(!context.shouldAbort)
        context.set()   // the load watchdog
        #expect(context.shouldAbort)
    }

    /// Hangs (until cancelled) on the whole-file prompt, answers others.
    final class HangsOnWholeFile: BuiltInRuntime, @unchecked Sendable {
        final class Model: LoadedModel, @unchecked Sendable {
            let started = Box(0)
            func generate(_ request: GenerationRequest) async throws -> GenerationResult {
                started.mutate { $0 += 1 }
                if request.user == "whole file" {
                    while !Task.isCancelled { try? await Task.sleep(nanoseconds: 2_000_000) }
                    throw BuiltInError.cancelled
                }
                return GenerationResult(text: "answer to " + request.user)
            }
            func unload() {}
        }
        let model = Model()
        func load(modelAt url: URL) async throws -> any LoadedModel { model }
    }

    @Test func hostCancelsAHangingGenerateAndTheNextOneRuns() async throws {
        let rt = HangsOnWholeFile()
        let host = BuiltInModelHost(runtime: rt)
        let path = URL(fileURLWithPath: "/tmp/a.gguf")
        let first = Task {
            try await BuiltInLoad.userAsked {
                try await host.generate(modelAt: path, GenerationRequest(system: "s", user: "whole file"))
            }
        }
        #expect(await eventually { rt.model.started.value == 1 })
        first.cancel()
        let r = try await BuiltInLoad.userAsked {
            try await host.generate(modelAt: path, GenerationRequest(system: "s", user: "9-line CSV"))
        }
        #expect(r.text == "answer to 9-line CSV")
        let firstResult = await first.result
        #expect(throws: BuiltInError.cancelled) { try firstResult.get() }
    }
}
