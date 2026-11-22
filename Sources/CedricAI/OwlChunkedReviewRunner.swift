import Foundation
import CedricCore

/// Plans against the exact per-part request and runs all parts on one engine.
public enum OwlChunkedReviewRunner {
    public struct Result: Sendable {
        public let outcome: OwlChatOutcome
        public let stopped: Bool
        public let error: String?
    }

    public static func eligible(_ request: OwlChatRequest) -> Bool {
        request.context.scope == .wholeDocument && request.inlineSelection == nil
            && ((request.action == nil && !OwlTools.asksForChange(request.question)) || request.action == .explain
                || request.action == .findProblems || request.action == .scriptSafety)
    }

    private static func partRequest(_ request: OwlChatRequest, part: OwlChunkedReview.Part) -> OwlChatRequest {
        var r = request
        r.context = OwlChatContext.reviewPart(r.snapshot, first: part.first, last: part.last)
        // Tools could read beyond this part and change the coverage being reported.
        r.useTools = false
        r.imageSource = nil
        if let findings = r.scanFindings {
            let inPart = findings.filter { (part.first...part.last).contains($0.line) }
            r.scan = inPart.isEmpty ? nil : ScriptSafety.summary(inPart)
        }
        r.reviewPartHeader = "Lines \(part.first)–\(part.last) of \(r.snapshot.countedLines)"
        return r
    }

    /// nil means the ordinary single request should be used.
    public static func plan(_ request: OwlChatRequest, engine: any OwlChatEngine) -> OwlChunkedReview.Plan? {
        guard eligible(request) else { return nil }
        var full = request
        full.context = OwlChatContext.reviewPart(request.snapshot, first: 1, last: request.snapshot.countedLines)
        if (full.context.numbered as NSString).length <= full.documentBudget(engineBudget: engine.contextBudget, server: engine.usesServer) {
            return nil
        }
        var budget = engine.contextBudget
        while true {
            let plan = OwlChunkedReview.plan(request.snapshot, budget: budget)
            let remaining = plan.parts.map { part in
                partRequest(request, part: part)
                    .documentBudget(engineBudget: engine.contextBudget, server: engine.usesServer)
            }.min() ?? 0
            if remaining >= budget { return plan }
            budget = remaining
        }
    }

    /// For an unchunked eligible request use the whole context, without a digest.
    public static func wholeRequest(_ request: OwlChatRequest) -> OwlChatRequest {
        guard eligible(request) else { return request }
        var r = request
        r.context = OwlChatContext.reviewPart(r.snapshot, first: 1, last: r.snapshot.countedLines)
        return r
    }

    public static func run(_ request: OwlChatRequest, plan: OwlChunkedReview.Plan, engine: any OwlChatEngine,
                           model: String = "", describeError: @Sendable (Error) -> String,
                           progress: @escaping @Sendable (Int, Int) -> Void) async -> Result {
        var answers: [String] = []
        var completed: [OwlChunkedReview.Part] = []
        var skipped: [OwlChunkedReview.Part] = []
        var stopped = false
        var errorMessage: String?
        for (index, part) in plan.parts.enumerated() {
            do {
                try Task.checkCancellation()
                progress(index + 1, plan.parts.count)
                if !part.fits {
                    skipped.append(part)
                    continue
                }
                let r = partRequest(request, part: part)
                let outcome = try await OwlChatRunner.run(r, engine: engine, model: model) { _ in }
                answers.append(outcome.modelAnswer)
                completed.append(part)
                try Task.checkCancellation()
            } catch {
                if error is CancellationError || (error as? LocalAIError) == .cancelled || (error as? BuiltInError) == .cancelled || Task.isCancelled {
                    stopped = true
                } else {
                    let reason = describeError(error)
                    errorMessage = String(localized: "The review stopped: \(reason)")
                }
                break
            }
        }

        var covered = IndexSet()
        for part in completed { covered.insert(integersIn: part.first...part.last) }
        let complete = covered.contains(integersIn: 1...plan.totalLines)
        let findings = request.action == .scriptSafety || request.action == .findProblems
        var text: String
        if findings {
            if request.action == .scriptSafety {
                var verdicts: [String] = []
                let withoutVerdicts = answers.map { answer in
                    answer.components(separatedBy: "\n").filter {
                        if ScriptVerdict.isVerdictLine($0) { verdicts.append($0); return false }
                        return true
                    }.joined(separator: "\n")
                }
                text = OwlChunkedReview.mergeFindings(withoutVerdicts)
                if let verdict = verdicts.max(by: { ScriptVerdict.severity(ofVerdict: $0) < ScriptVerdict.severity(ofVerdict: $1) }) {
                    text += (text.isEmpty ? "" : "\n\n") + verdict
                }
            } else {
                text = OwlChunkedReview.mergeFindings(answers)
            }
        } else {
            text = answers.joined(separator: "\n\n")
        }

        if !findings, !stopped, errorMessage == nil, !answers.isEmpty {
            let userRequest = request.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? request.action.map {
                    OwlPrompts.quickInstruction($0, prose: request.prose, toolsOn: false,
                                                context: OwlChatContext.reviewPart(request.snapshot, first: 1, last: plan.totalLines))
                } ?? request.question
                : request.question
            let instruction = "Answer the user's request with one brief response based only on these reviewed answers. "
                + "Keep real file line numbers. Do not invent details from lines not reviewed or mention the review process.\n\n"
                + "User's request: \(userRequest)\n\nReviewed answers:\n" + text
            let system = OwlPrompts.chatSystem(toolsOn: false, server: engine.usesServer, partial: !complete)
            let room = OwlInlineAssist.documentBudget(engineBudget: engine.contextBudget, instructionWrapper: instruction,
                                                       systemPrompt: system, history: request.history)
            if room > 0 {
                do {
                    try Task.checkCancellation()
                    let messages: [OwlChatMessage] = [.system(system)] + OwlPrompts.chatHistoryMessages(request.history) + [.user(instruction)]
                    let streamed = TextBuffer()
                    let turn = try await engine.turn(messages, tools: [], toolbox: nil, maxTokens: request.maxTokens) { streamed.append($0) }
                    if case .answer(let answer) = turn {
                        let combined = OwlChatRunner.stripThinking(answer)
                        let final = combined.isEmpty ? OwlChatRunner.stripThinking(streamed.value) : combined
                        if final.isEmpty {
                            errorMessage = errorMessage ?? String(localized: "The model returned no combined answer; the reviewed answers are shown below.")
                        } else {
                            text = final
                        }
                    } else {
                        errorMessage = errorMessage ?? String(localized: "The model did not return a combined answer; the reviewed answers are shown below.")
                    }
                    try Task.checkCancellation()
                } catch {
                    if error is CancellationError || (error as? LocalAIError) == .cancelled || (error as? BuiltInError) == .cancelled || Task.isCancelled {
                        stopped = true
                    } else {
                        errorMessage = errorMessage ?? String(localized: "The review could not combine the answers: \(describeError(error))")
                    }
                }
            } else {
                text = String(localized: "The reviewed answers are shown separately.") + "\n\n" + text
            }
        }
        if !skipped.isEmpty {
            let lines = skipped.map {
                $0.first == $0.last
                    ? String(localized: "Line \($0.first) was too long for this model and was not reviewed.")
                    : String(localized: "Lines \($0.first)–\($0.last) were too long for this model and were not reviewed.")
            }.joined(separator: "\n")
            text = lines + (text.isEmpty ? "" : "\n\n" + text)
        }
        if !complete {
            let note: String
            if let first = completed.first, let last = completed.last {
                note = String(localized: "Reviewed lines \(first.first)–\(last.last) of \(plan.totalLines); the rest was not reviewed.")
            } else {
                note = String(localized: "No document lines were reviewed.")
            }
            text = note + (text.isEmpty ? "" : "\n\n" + text)
        }
        if let mode = request.safeClaimGuard {
            let forced = request.action == .scriptSafety
                ? OwlChunkedReview.forcedVerdict(scanHasHigh: request.scanHasHigh, scanTruncated: request.scanTruncated,
                                                 covered: covered, totalLines: plan.totalLines) : nil
            text = ScriptVerdict.clamp(text, forced: forced, guard: mode)
        }
        if stopped { text += (text.isEmpty ? "" : "\n\n") + String(localized: "Stopped.") }
        if let errorMessage { text += (text.isEmpty ? "" : "\n\n") + errorMessage }
        return Result(outcome: OwlChatOutcome(answer: text, proposals: [], toolCalls: 0, rounds: 0),
                      stopped: stopped, error: errorMessage)
    }
}
