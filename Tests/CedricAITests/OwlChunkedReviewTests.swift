import Foundation
import Testing
@testable import CedricAI
import CedricCore

@Suite struct OwlChunkedReviewTests {
    actor Gate {
        var started = false
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            started = true
            await withCheckedContinuation { waiter = $0 }
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    final class Engine: OwlChatEngine, @unchecked Sendable {
        let contextBudget: Int
        let gate: Gate?
        let failAt: Int?
        let reply: String
        let replies: [Int: String]
        private let lock = NSLock()
        private var _calls = 0
        private var _messages: [[OwlChatMessage]] = []
        var calls: Int { lock.withLock { _calls } }
        var messages: [[OwlChatMessage]] { lock.withLock { _messages } }
        var title: String { "test" }
        var scoreKey: String { "test" }
        init(budget: Int = 5_000, gate: Gate? = nil, failAt: Int? = nil,
             reply: String = "Line 10: A finding.\nVerdict: No obvious red flags (not a guarantee).",
             replies: [Int: String] = [:]) {
            contextBudget = budget; self.gate = gate; self.failAt = failAt; self.reply = reply; self.replies = replies
        }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            let call = lock.withLock {
                _calls += 1
                _messages.append(messages)
                return _calls
            }
            if call == 1, let gate { await gate.wait() }
            if call == failAt { throw LocalAIError.http(503) }
            let text = replies[call] ?? reply
            onText(text)
            return .answer(text)
        }
    }

    static func snapshot(lines: Int = 263) -> OwlDocumentSnapshot {
        let text = (1...lines).map { i in
            let prefix = "line-\(i) "
            return prefix + String(repeating: "x", count: max(0, (i <= 52 ? 36 : 35) - prefix.count))
        }.joined(separator: "\n")
        let ns = text as NSString
        let caret = ns.range(of: "line-\(min(lines, 132)) ").location
        return OwlDocumentSnapshot(text: text, generation: 1, selection: NSRange(location: caret, length: 0), language: "python")
    }

    /// UTF-16 units a call sends (what `contextBudget` limits).
    static func size(_ messages: [OwlChatMessage]) -> Int {
        messages.reduce(0) { total, m in
            switch m {
            case .system(let t), .user(let t), .assistant(let t): return total + (t as NSString).length
            default: return total
            }
        }
    }

    static func request(_ s: OwlDocumentSnapshot, action: OwlQuickAction?, question: String = "What does this script do?") -> OwlChatRequest {
        OwlChatRequest(question: question, action: action,
                       context: OwlChatContext.reviewPart(s, first: 1, last: s.countedLines),
                       snapshot: s, useTools: false, prose: false)
    }

    @Test func boundariesOverlapAndCoverage() throws {
        let s = Self.snapshot(lines: 100)
        let budget = 1_000
        let plan = OwlChunkedReview.plan(s, budget: budget)
        #expect(plan.parts.count > 1 && plan.isComplete)
        var covered = IndexSet()
        for part in plan.parts {
            #expect((part.numbered as NSString).length <= budget)
            #expect(part.numbered == s.numbered(lines: part.first, part.last))
            covered.insert(integersIn: part.first...part.last)
        }
        for (a, b) in zip(plan.parts, plan.parts.dropFirst()) {
            #expect(a.last - b.first + 1 == OwlChunkedReview.overlapLines)
        }
        #expect(covered.contains(integersIn: 1...s.countedLines))
        #expect(OwlChunkedReview.overlapLines == 2)
        let long = OwlDocumentSnapshot(text: String(repeating: "x", count: 300) + "\ny", generation: 1)
        let oversize = OwlChunkedReview.plan(long, budget: 50)
        #expect(oversize.parts.first?.last == 1 && oversize.parts.first?.fits == false && !oversize.isComplete)
    }

    @Test func findingDeduplicationPreservesLineNumbers() {
        let merged = OwlChunkedReview.mergeFindings(["- Line 12: High: first.\n- Line 13: Medium: distinct.",
                                                     "- Line 12: Low: duplicate.\n  Duplicate detail.\n- Line 98: High: another."])
        #expect(merged.contains("Line 12: High: first"))
        #expect(!merged.localizedCaseInsensitiveContains("duplicate"))
        #expect(merged.contains("Line 13") && merged.contains("Line 98"))
        let alternate = OwlChunkedReview.mergeFindings(["- 12: First", "- Line 12: Duplicate", "98| Other"])
        #expect(alternate.contains("- 12: First") && !alternate.contains("Duplicate") && alternate.contains("98| Other"))
        let sameLine = OwlChunkedReview.mergeFindings(["- Line 12: pipes curl to sh.\n- Line 12: also writes /etc/hosts."])
        #expect(sameLine.contains("pipes curl to sh") && sameLine.contains("also writes /etc/hosts"))
    }

    @Test func noCapAndVerdicts() {
        let s = Self.snapshot(lines: 500)
        let plan = OwlChunkedReview.plan(s, budget: 400)
        // Every part is planned (0.5.2 kept a window of 8 around the caret).
        #expect(plan.parts.count > 8 && plan.isComplete)
        #expect(plan.parts.contains { $0.first <= 132 && $0.last >= 132 })
        #expect(plan.parts.first?.first == 1 && plan.parts.last?.last == 500)
        var covered = IndexSet()
        for part in plan.parts.prefix(8) { covered.insert(integersIn: part.first...part.last) }
        #expect(OwlChunkedReview.forcedVerdict(scanHasHigh: false, scanTruncated: false, covered: covered, totalLines: 500) == .truncated)
        let all = IndexSet(integersIn: 1...500)
        #expect(OwlChunkedReview.forcedVerdict(scanHasHigh: false, scanTruncated: false, covered: all, totalLines: 500) == nil)
        #expect(OwlChunkedReview.forcedVerdict(scanHasHigh: false, scanTruncated: true, covered: all, totalLines: 500) == .truncated)
        #expect(OwlChunkedReview.forcedVerdict(scanHasHigh: true, scanTruncated: true, covered: covered, totalLines: 500) == .highFinding)
    }

    @Test func cancellationKeepsCompletedPartAndStopsBeforeNext() async throws {
        let gate = Gate()
        let engine = Engine(gate: gate)
        let req = Self.request(Self.snapshot(), action: .findProblems)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let task = Task {
            await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine, describeError: { String(describing: $0) }) { _, _ in }
        }
        while !(await gate.started) { await Task.yield() }
        task.cancel()
        await gate.release()
        let result = await task.value
        #expect(engine.calls == 1 && result.stopped)
        #expect(result.outcome.answer.contains("Line 10") && result.outcome.answer.contains("Stopped."))
        #expect(result.outcome.answer.contains("rest was not reviewed"))
    }

    @Test func errorKeepsEarlierResultsAndForcesPartialVerdict() async throws {
        let engine = Engine(failAt: 2, reply: "Line 10: A risk.\nVerdict: safe to run.")
        let req = Self.request(Self.snapshot(), action: .scriptSafety)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                      describeError: { _ in "Engine error" }) { _, _ in }
        #expect(engine.calls == 2 && !result.stopped)
        #expect(result.error?.contains("The review stopped: Engine error") == true)
        #expect(!result.outcome.answer.localizedCaseInsensitiveContains("part 2 of"))
        #expect(result.outcome.answer.contains("Line 10") && result.outcome.answer.contains("rest was not reviewed"))
        #expect(result.outcome.answer.contains(ScriptVerdict.Reason.truncated.note))
        #expect(!result.outcome.answer.lowercased().contains("safe to run"))
    }

    @Test func failedPartOnATypedQuestionDoesNotCombineAndKeepsTheCause() async throws {
        let engine = Engine(failAt: 2, reply: "The opening section sets up the script.")
        let req = try #require((80...400).lazy.map {
            Self.request(Self.snapshot(lines: $0), action: nil, question: "What does this file do?")
        }.first { OwlChunkedReviewRunner.plan($0, engine: engine)?.parts.count == 3 })
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                      describeError: { _ in "Engine error" }) { _, _ in }
        #expect(engine.calls == 2 && !result.stopped)
        #expect(result.error == "The review stopped: Engine error")
        #expect(result.outcome.answer.contains("The opening section sets up the script."))
        #expect(result.outcome.answer.contains("The review stopped: Engine error"))
        #expect(!result.outcome.answer.localizedCaseInsensitiveContains("could not combine"))
        #expect(!result.outcome.answer.contains("Part 1"))
        #expect(!result.outcome.answer.localizedCaseInsensitiveContains("part 1 of"))
        #expect(!result.outcome.answer.localizedCaseInsensitiveContains("part 2 of"))
    }

    @Test func scopeAndActionExclusions() {
        let s = Self.snapshot()
        // Summarise reads the whole document in parts now (0.5.2 trimmed it to fit).
        for action in [OwlQuickAction.rewrite, .addComments, .explainLine] {
            #expect(OwlChunkedReviewRunner.plan(Self.request(s, action: action), engine: Engine()) == nil)
        }
        #expect(OwlChunkedReviewRunner.plan(Self.request(s, action: nil, question: "Please rewrite this file"), engine: Engine()) == nil)
        #expect(OwlChunkedReviewRunner.plan(Self.request(s, action: .summarise), engine: Engine()) != nil)
        for scope in [OwlChatScope.visible, .selection] {
            let selected = OwlDocumentSnapshot(text: s.text, generation: 1, selection: NSRange(location: 0, length: 10), language: "python")
            let context = OwlChatContext.build(selected, scope: scope, budget: 200)!
            let request = OwlChatRequest(question: "Explain", action: .explain, context: context, snapshot: selected,
                                         useTools: false, prose: false)
            #expect(OwlChunkedReviewRunner.plan(request, engine: Engine()) == nil)
        }
    }

    @Test func largeSummariesAreCombinedInRoundsWithoutPartLabels() async throws {
        let engine = Engine(reply: String(repeating: "summary ", count: 800))
        let req = Self.request(Self.snapshot(), action: .explain)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                      describeError: { String(describing: $0) }) { _, _ in }
        // Notes too long for one combine call are merged in groups first,
        // then combined: one answer, never the parts stacked.
        #expect(result.error == nil && !result.stopped)
        #expect(result.reduceCalls > 1 && engine.calls == plan.parts.count + result.reduceCalls)
        #expect(result.outcome.answer.contains("summary"))
        #expect(result.outcome.answer.components(separatedBy: "\n\n").filter { $0.contains("summary") }.count == 1)
        #expect(result.outcome.sections.count == plan.parts.count)
        #expect(!result.outcome.answer.contains("Part 1 (lines"))
        #expect(!result.outcome.answer.localizedCaseInsensitiveContains("part 1 of"))
        for messages in engine.messages { #expect(Self.size(messages) <= engine.contextBudget) }
    }

    @Test func chunkedScriptVerdictRespectsScan() async throws {
        let engine = Engine()
        var req = Self.request(Self.snapshot(), action: .scriptSafety)
        req.scanHasHigh = true
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                      describeError: { String(describing: $0) }) { _, _ in }
        #expect(result.outcome.answer.contains(ScriptVerdict.Reason.highFinding.note))
        #expect(!result.outcome.answer.contains(ScriptVerdict.Reason.truncated.note))
    }

    @Test func longScriptReviewCoversEveryLineWithoutForcingTheVerdict() async throws {
        let engine = Engine(budget: 3_000)
        let req = Self.request(Self.snapshot(lines: 500), action: .scriptSafety)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        #expect(plan.parts.count > 8 && plan.isComplete)
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                      describeError: { String(describing: $0) }) { _, _ in }
        #expect(engine.calls == plan.parts.count)
        #expect(!result.outcome.answer.contains("rest was not reviewed"))
        #expect(!result.outcome.answer.contains(ScriptVerdict.Reason.truncated.note))
        #expect(result.outcome.answer.contains("Line 10"))
    }

    @Test func longExplanationCoversEveryLineAndCombines() async throws {
        let engine = Engine(budget: 3_000, reply: "A brief part.")
        let req = Self.request(Self.snapshot(lines: 1_000), action: .explain)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        #expect(plan.isComplete && plan.parts.count > 8)
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                      describeError: { String(describing: $0) }) { _, _ in }
        #expect(engine.calls == plan.parts.count + result.reduceCalls && result.reduceCalls >= 1)
        #expect(!result.outcome.answer.contains("rest was not reviewed"))
        #expect(result.outcome.answer == "A brief part.")
    }

    @Test func scriptPartsReceiveOnlyTheirScanFindings() async throws {
        let lines = (1...263).map { i in
            i == 10 || i == 240 ? "exec(requests.get(url))" : "print('padding to fill the model context')"
        }
        let s = OwlDocumentSnapshot(text: lines.joined(separator: "\n"), generation: 1, language: "python")
        let report = ScriptSafety.check(s.text, language: .python)
        #expect(report.findings.contains { $0.line == 10 } && report.findings.contains { $0.line == 240 })
        var req = Self.request(s, action: .scriptSafety)
        req.scan = ScriptSafety.summary(report)
        req.scanFindings = report.findings
        let engine = Engine()
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        _ = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                             describeError: { String(describing: $0) }) { _, _ in }
        for (index, part) in plan.parts.enumerated() {
            guard case .user(let user)? = engine.messages[index].last else { Issue.record("Missing user prompt"); continue }
            #expect(user.contains("- line 10 ") == (part.first...part.last).contains(10))
            #expect(user.contains("- line 240 ") == (part.first...part.last).contains(240))
        }
    }

    @Test func requestsAndCombination() async throws {
        let short = Self.request(Self.snapshot(lines: 5), action: .findProblems)
        let single = Engine()
        #expect(OwlChunkedReviewRunner.plan(short, engine: single) == nil)
        _ = try await OwlChatRunner.run(OwlChunkedReviewRunner.wholeRequest(short), engine: single) { _ in }
        #expect(single.calls == 1)

        // Pick a deterministic document size requiring exactly three parts for each action.
        for action in [OwlQuickAction?.some(.scriptSafety), .findProblems, .explain, nil] {
            let engine = Engine()
            let req = try #require((80...400).lazy.map { Self.request(Self.snapshot(lines: $0), action: action) }
                .first { OwlChunkedReviewRunner.plan($0, engine: engine)?.parts.count == 3 })
            let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
            let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                          describeError: { String(describing: $0) }) { _, _ in }
            #expect(!result.stopped && result.error == nil)
            #expect(engine.calls == (action == .explain || action == nil ? 4 : 3))
            #expect(!result.outcome.answer.contains("Part 1"))
            #expect(!result.outcome.answer.localizedCaseInsensitiveContains("part 1 of"))
            for (index, part) in plan.parts.enumerated() {
                let messages = engine.messages[index]
                guard case .user(let user)? = messages.last else { Issue.record("Missing user prompt"); continue }
                #expect(user.contains("Lines \(part.first)–\(part.last) of \(plan.totalLines)"))
                #expect(!user.localizedCaseInsensitiveContains("part \(index + 1) of"))
                #expect(!user.contains("OUTLINE OF THE WHOLE DOCUMENT"))
                let chunk = OwlChatContext.reviewPart(req.snapshot, first: part.first, last: part.last)
                #expect(chunk.numbered == part.numbered)
            }
            if action == .scriptSafety {
                #expect(!result.outcome.answer.contains("Only part of the script was reviewed"))
            }
        }
    }

    @Test func largePythonScriptPartCountsOnAppleIntelligenceBudget() throws {
        let s = Self.snapshot()
        #expect(s.length == 9_519 && s.countedLines == 263)
        let engine = Engine()
        for action in [OwlQuickAction?.some(.scriptSafety), nil] {
            let req = Self.request(s, action: action, question: action == nil ? "What does this script do?" : "Check this script for risks.")
            let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
            #expect(plan.parts.count > 1 && plan.isComplete)
            for part in plan.parts {
                var r = req
                r.context = OwlChatContext.reviewPart(s, first: part.first, last: part.last)
                r.reviewPartHeader = "Lines \(part.first)–\(part.last) of 263"
                #expect((part.numbered as NSString).length <= r.documentBudget(engineBudget: 5_000, server: false))
                #expect(r.contextAdditions(engineBudget: 5_000).digest == nil)
            }
        }
    }

    @Test func typedWholeDocumentQuestionCombinesItsPartAnswers() async throws {
        let engine = Engine(replies: [
            1: "The file defines its first behavior.",
            2: "The file defines its second behavior.",
            3: "The file defines its third behavior.",
            4: "The file defines three behaviors, each with its own purpose."
        ])
        let req = try #require((80...400).lazy.map {
            Self.request(Self.snapshot(lines: $0), action: nil, question: "Summarize the behavior of this file.")
        }.first { OwlChunkedReviewRunner.plan($0, engine: engine)?.parts.count == 3 })
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                      describeError: { String(describing: $0) }) { _, _ in }
        #expect(engine.calls == plan.parts.count + 1)
        #expect(result.outcome.answer == "The file defines three behaviors, each with its own purpose.")
        #expect(!result.outcome.answer.contains("Part 1"))
        #expect(!result.outcome.answer.localizedCaseInsensitiveContains("part 1 of"))
    }

    @Test func chunkingOnlyWhenWholeDocumentExceedsBudget() throws {
        let s = Self.snapshot()
        #expect(s.length == 9_519 && s.countedLines == 263)
        let req = Self.request(s, action: nil)
        #expect(OwlChunkedReviewRunner.plan(req, engine: Engine(budget: 24_000)) == nil)
        #expect(OwlChunkedReviewRunner.plan(req, engine: Engine(budget: 32_000)) == nil)
        let appleBudgetPlan = try #require(OwlChunkedReviewRunner.plan(req, engine: Engine(budget: 5_000)))
        #expect(appleBudgetPlan.parts.count > 1)
    }

    @Test func curlyApostropheDontRunOutranksAReassuringVerdict() async throws {
        #expect(ScriptVerdict.severity(ofVerdict: "Verdict: Don’t run it.") == 2)
        #expect(ScriptVerdict.severity(ofVerdict: "Verdict: Don't run it.") == 2)
        #expect(ScriptVerdict.severity(ofVerdict: "Verdict: No obvious red flags (not a guarantee).") == 0)
        let engine = Engine()
        let req = try #require((80...400).lazy.map { Self.request(Self.snapshot(lines: $0), action: .scriptSafety) }
            .first { OwlChunkedReviewRunner.plan($0, engine: engine)?.parts.count == 2 })
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let mixed = Engine(replies: [
            1: "Line 2: looks ordinary.\nVerdict: No obvious red flags (not a guarantee).",
            2: "Line 40: downloads and runs a script.\nVerdict: Don’t run it."
        ])
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: mixed,
                                                      describeError: { String(describing: $0) }) { _, _ in }
        #expect(mixed.calls == 2)
        #expect(result.outcome.answer.localizedCaseInsensitiveContains("don’t run")
               || result.outcome.answer.localizedCaseInsensitiveContains("don't run"))
        #expect(!result.outcome.answer.contains(ScriptVerdict.noRedFlags))
    }

    @Test func oversizeLineIsNotClaimedCovered() async throws {
        let s = OwlDocumentSnapshot(text: String(repeating: "x", count: 300) + "\nprint(1)\n", generation: 1,
                                    language: "python")
        var req = Self.request(s, action: .scriptSafety)
        req.context = OwlChatContext.reviewPart(s, first: 1, last: s.countedLines)
        let engine = Engine(budget: 50)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        #expect(!plan.isComplete && plan.parts.contains { !$0.fits })
        let result = await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine,
                                                      describeError: { String(describing: $0) }) { _, _ in }
        #expect(engine.calls == plan.parts.filter(\.fits).count)
        #expect(result.outcome.answer.contains("too long for this model"))
        #expect(result.outcome.answer.contains(ScriptVerdict.Reason.truncated.note))
        #expect(!result.outcome.answer.contains("Whole document"))
    }
}
