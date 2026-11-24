import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Whole-document asks as map-reduce (0.5.3): every line read in parts,
/// one combined answer first, the parts' notes kept below; Summarise on
/// the same path; citations kept to the lines each call was given.
@Suite struct OwlWholeDocSynthesisTests {
    /// Records every call. Part calls answer with `partReply` (given the
    /// part's lines); a combine call (final or group merge) with `reduceReply`.
    final class Recorder: OwlChatEngine, @unchecked Sendable {
        let contextBudget: Int
        let partReply: @Sendable (Int, Int) -> String
        let reduceReply: @Sendable (String) -> String
        private let lock = NSLock()
        private var _calls: [[OwlChatMessage]] = []
        var calls: [[OwlChatMessage]] { lock.withLock { _calls } }
        var title: String { "recorder" }
        var scoreKey: String { "recorder" }
        init(budget: Int = 5_000,
             partReply: @escaping @Sendable (Int, Int) -> String = { a, b in "- Line \(a) opens this part.\n- Line \(b) closes it." },
             reduceReply: @escaping @Sendable (String) -> String = { _ in "One summary of the whole document, from line 1 on." }) {
            contextBudget = budget; self.partReply = partReply; self.reduceReply = reduceReply
        }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            lock.withLock { _calls.append(messages) }
            let user = Self.user(messages)
            let text: String
            if Self.isReduce(user) {
                text = reduceReply(user)
            } else {
                let re = try! NSRegularExpression(pattern: #"Lines (\d+)–(\d+) of \d+"#)
                let ns = user as NSString
                let m = re.firstMatch(in: user, range: NSRange(location: 0, length: ns.length))
                let a = m.map { Int(ns.substring(with: $0.range(at: 1)))! } ?? 1
                let b = m.map { Int(ns.substring(with: $0.range(at: 2)))! } ?? 1
                text = partReply(a, b)
            }
            onText(text)
            return .answer(text)
        }
        static func user(_ messages: [OwlChatMessage]) -> String {
            if case .user(let u)? = messages.last { return u }
            return ""
        }
        static func isReduce(_ user: String) -> Bool {
            user.contains(OwlChunkedReviewRunner.notesLabel) || user.contains(OwlChunkedReviewRunner.groupNotesLabel)
        }
        var reduceCalls: [[OwlChatMessage]] { calls.filter { Self.isReduce(Self.user($0)) } }
        var partCalls: [[OwlChatMessage]] { calls.filter { !Self.isReduce(Self.user($0)) } }
    }

    static func size(_ messages: [OwlChatMessage]) -> Int {
        messages.reduce(0) { total, m in
            switch m {
            case .system(let t), .user(let t), .assistant(let t): return total + (t as NSString).length
            default: return total
            }
        }
    }

    /// A 282-line Markdown document like the one asked about on iPad: front
    /// matter, headings, prose lines of varied length.
    static func doc282() -> OwlDocumentSnapshot {
        var lines = ["---", "title: Field notes", "date: 2026-11-20", "---"]
        var i = 0
        while lines.count < 282 {
            i += 1
            if i % 25 == 1 { lines.append("## Section \(i / 25 + 1)"); continue }
            let words = 8 + (i * 7) % 12
            lines.append("Note \(i): " + (0..<words).map { w in ["the", "river", "walked", "slowly", "past", "older", "stones", "while"][(i + w) % 8] }
                .joined(separator: " ") + ".")
        }
        return OwlDocumentSnapshot(text: lines.joined(separator: "\n") + "\n", generation: 1, fileName: "notes.md",
                                   language: "markdown")
    }

    static func big(_ n: Int) -> OwlDocumentSnapshot {
        let text = (1...n).map { "row \($0): " + String(repeating: "v", count: 20 + $0 % 30) }.joined(separator: "\n")
        return OwlDocumentSnapshot(text: text, generation: 1, fileName: "big.txt", language: "plain")
    }

    /// The request the panel builds: the ordinary (trimmed) context for the scope.
    static func request(_ s: OwlDocumentSnapshot, action: OwlQuickAction?, question: String = "What is this document about?",
                        budget: Int = 5_000, history: [OwlChatEntry] = []) -> OwlChatRequest {
        let prose = s.language == "markdown" || s.language == "plain"
        let ctx = OwlChatRequest.documentContext(s, scope: .wholeDocument, engineBudget: budget, history: history,
                                                 question: question, action: action, tools: false, server: false,
                                                 prose: prose)!
        return OwlChatRequest(question: question, action: action, context: ctx, snapshot: s, history: history,
                              useTools: false, prose: prose)
    }

    static func covered(_ plan: OwlChunkedReview.Plan) -> IndexSet {
        var c = IndexSet()
        for p in plan.parts where p.fits { c.insert(integersIn: p.first...p.last) }
        return c
    }

    static func run(_ req: OwlChatRequest, _ plan: OwlChunkedReview.Plan, _ engine: any OwlChatEngine) async -> OwlChunkedReviewRunner.Result {
        await OwlChunkedReviewRunner.run(req, plan: plan, engine: engine, describeError: { String(describing: $0) }) { _, _ in }
    }

    // MARK: Reduce

    @Test func reduceRunsAfterTheMapPassWithTheQuestionAndCompactNotes() async throws {
        let engine = Recorder()
        let req = Self.request(Self.doc282(), action: nil, question: "What are the main themes?")
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await Self.run(req, plan, engine)
        #expect(result.error == nil && !result.stopped)
        // Every part first, then the one combine call, last.
        #expect(engine.partCalls.count == plan.parts.count)
        #expect(engine.reduceCalls.count == 1 && result.reduceCalls == 1)
        let last = Recorder.user(engine.calls.last!)
        #expect(last.contains(OwlChunkedReviewRunner.notesLabel))
        #expect(last.hasPrefix("What are the main themes?"))
        for part in plan.parts { #expect(last.contains("Lines \(part.first)–\(part.last):")) }
        // Compact notes, not the document: no numbered document lines in it.
        #expect(!last.contains("5| Note"))
        // The combined answer is the answer; the part answers are its notes.
        #expect(result.outcome.answer == "One summary of the whole document, from line 1 on.")
        #expect(result.outcome.sections.map(\.first) == plan.parts.map(\.first))
        #expect(result.outcome.sections.allSatisfy { $0.text.contains("opens this part") })
        #expect(!result.outcome.answer.contains("opens this part"))
        // The combine call is told not to describe the process or new edits.
        #expect(last.contains("don't mention notes, parts, sections or a review"))
        #expect(last.contains("don't propose or describe new edits"))
    }

    @Test func reduceUsesFakeChatEngineEndToEnd() async throws {
        let engine = FakeChatEngine(delay: 0, pieces: 1)
        let req = Self.request(Self.big(600), action: .summarise, budget: engine.contextBudget)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        #expect(plan.isComplete && plan.parts.count > 1)
        let result = await Self.run(req, plan, engine)
        #expect(result.error == nil && !result.stopped && result.reduceCalls >= 1)
        #expect(result.outcome.sections.count == plan.parts.count)
        #expect(result.outcome.proposals.isEmpty)
        #expect(!result.outcome.answer.isEmpty)
    }

    @Test func noReduceCallExceedsTheEngineBudget() async throws {
        // Long part notes: one combine call can't hold them all.
        let long: @Sendable (Int, Int) -> String = { a, b in
            (a...min(b, a + 11)).map { "- Line \($0): " + String(repeating: "detail ", count: 22) }.joined(separator: "\n")
        }
        for budget in [5_000, 3_200] {
            let engine = Recorder(budget: budget, partReply: long,
                                  reduceReply: { u in u.contains(OwlChunkedReviewRunner.notesLabel) ? "Combined." : "- Line 1: merged " + String(repeating: "m", count: 3_000) })
            let req = Self.request(Self.doc282(), action: .summarise, budget: budget)
            let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
            let result = await Self.run(req, plan, engine)
            #expect(result.error == nil && !result.stopped, "budget \(budget)")
            #expect(engine.reduceCalls.count > 1, "the notes were merged in groups first (budget \(budget))")
            for call in engine.calls { #expect(Self.size(call) <= budget, "budget \(budget)") }
            #expect(result.outcome.answer == "Combined.")
        }
    }

    // MARK: Coverage

    @Test func a282LineDocumentOnAppleIntelligenceIsCoveredWhole() async throws {
        let s = Self.doc282()
        #expect(s.countedLines == 282)
        for action in [OwlQuickAction?.none, .summarise, .explain, .findProblems] {
            let engine = Recorder(budget: 5_000)
            let req = Self.request(s, action: action)
            let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
            // More parts than 0.5.2's window of 8 (which stopped at line 236).
            #expect(plan.parts.count > 8)
            #expect(Self.covered(plan).contains(integersIn: 1...282) && plan.isComplete)
            let label = OwlChunkedReviewRunner.scopeLabel(req, engine: engine)
            #expect(label == "Whole document (282 lines)")
            #expect(!label.contains("trimmed") && !label.contains("not reviewed"))
            let result = await Self.run(req, plan, engine)
            #expect(engine.partCalls.count == plan.parts.count)
            #expect(!result.outcome.answer.contains("not reviewed") && !result.outcome.answer.contains("trimmed to fit"))
            // Every part call stayed in the budget.
            for call in engine.partCalls { #expect(Self.size(call) <= 5_000) }
        }
    }

    @Test func theChipBeforeAskingNeverSaysTrimmedForTheWholeDocument() {
        let s = Self.doc282()
        let preview = OwlChatRequest.documentContext(s, scope: .wholeDocument, engineBudget: 5_000, history: [], question: "",
                                                     action: nil, tools: false, server: false, prose: true, preview: true)!
        #expect(preview.truncated && preview.label.contains("trimmed to fit"))
        #expect(OwlChunkedReviewRunner.previewLabel(preview) == "Whole document (282 lines)")
        // Selection and visible scopes keep their own labels.
        let visible = OwlChatContext.build(s, scope: .visible, budget: 200)!
        #expect(OwlChunkedReviewRunner.previewLabel(visible) == visible.label)
    }

    @Test func longEarlierAnswersDoNotShrinkThePartsToNothing() throws {
        let s = Self.doc282()
        let long = String(repeating: "An earlier long answer about lines 1–236. ", count: 40)
        let history = [OwlChatEntry(role: .user, text: "What is this?"), OwlChatEntry(role: .owl, text: long),
                       OwlChatEntry(role: .user, text: "And the dates?"), OwlChatEntry(role: .owl, text: long)]
        let engine = Recorder(budget: 5_000)
        let req = Self.request(s, action: .summarise, history: history)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        #expect(plan.isComplete && plan.parts.allSatisfy(\.fits))
    }

    @Test func bigDocumentsOnASmallBudgetAreCoveredWhole() async throws {
        for (n, budget) in [(2_000, 3_000), (5_000, 5_000)] {
            let s = Self.big(n)
            let engine = Recorder(budget: budget)
            let req = Self.request(s, action: .summarise, budget: budget)
            let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
            #expect(plan.isComplete, "\(n) lines")
            #expect(plan.parts.first?.first == 1 && plan.parts.last?.last == n)
            for (a, b) in zip(plan.parts, plan.parts.dropFirst()) { #expect(b.first <= a.last + 1) }
            #expect(OwlChunkedReview.label(plan) == String(localized: "Whole document (\(n) lines)"))
            #expect(!OwlChunkedReview.label(plan).contains("trimmed") && !OwlChunkedReview.label(plan).contains("not reviewed"))
            let result = await Self.run(req, plan, engine)
            #expect(result.error == nil && !result.stopped)
            #expect(engine.partCalls.count == plan.parts.count)
            #expect(result.reduceCalls > 1, "hierarchical: \(plan.parts.count) parts' notes")
            for call in engine.calls { #expect(Self.size(call) <= budget) }
            #expect(result.outcome.answer == "One summary of the whole document, from line 1 on.")
        }
    }

    // MARK: Summarise and the other whole-document actions

    @Test func summariseIsReadInPartsNotTrimmedToFit() async throws {
        let s = Self.doc282()
        let engine = Recorder(budget: 5_000)
        let req = Self.request(s, action: .summarise)
        // The ordinary context is trimmed on this budget (0.5.2's chip) …
        #expect(req.context.truncated && req.context.label.contains("trimmed to fit"))
        // … but Summarise now reads every line in parts.
        #expect(OwlChunkedReviewRunner.eligible(req))
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let label = OwlChunkedReviewRunner.scopeLabel(req, engine: engine)
        #expect(label != req.context.label && !label.contains("trimmed to fit"))
        let result = await Self.run(req, plan, engine)
        let parts = engine.partCalls.map(Recorder.user)
        #expect(parts.count == plan.parts.count && parts.allSatisfy { $0.contains("Summarise this text") })
        #expect(parts.last?.contains("Lines \(plan.parts.last!.first)–282 of 282") == true)
        // The combine call asks for the summary of the whole document.
        let final = Recorder.user(engine.reduceCalls.last!)
        #expect(final.hasPrefix("Summarise this text (lines 1-282) in at most 5 short bullet points."))
        #expect(result.outcome.answer == "One summary of the whole document, from line 1 on.")
        // Edit actions stay off this path: they never get a combine call.
        for action in [OwlQuickAction.rewrite, .addComments] {
            #expect(!OwlChunkedReviewRunner.eligible(Self.request(s, action: action)))
        }
    }

    @Test func findingsAreMergedNotRewrittenAndKeepTheirLines() async throws {
        let engine = Recorder(partReply: { a, _ in "- Line \(a + 1): a real problem." })
        let req = Self.request(Self.doc282(), action: .findProblems)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await Self.run(req, plan, engine)
        #expect(engine.reduceCalls.isEmpty)
        for part in plan.parts { #expect(result.outcome.answer.contains("Line \(part.first + 1): a real problem.")) }
    }

    // MARK: Citations

    @Test func partAnswersKeepOnlyTheirOwnLines() async throws {
        // Each part also "cites" a line far outside it.
        let engine = Recorder(partReply: { a, b in "- Line \(a): opens.\n- Line \(b + 500): invented." })
        let req = Self.request(Self.doc282(), action: .summarise)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await Self.run(req, plan, engine)
        for (part, note) in zip(plan.parts, result.outcome.sections) {
            #expect(note.text.contains("Line \(part.first): opens."))
            #expect(!note.text.contains("invented"))
        }
        #expect(!Recorder.user(engine.reduceCalls.last!).contains("invented"))
    }

    @Test func theCombinedAnswerCannotCiteALineNoPartRead() async throws {
        // Line 3 is longer than the whole budget: no part reads it.
        var lines = (1...120).map { "line \($0) " + String(repeating: "w", count: 40) }
        lines[2] = String(repeating: "z", count: 6_000)
        let s = OwlDocumentSnapshot(text: lines.joined(separator: "\n"), generation: 1, fileName: "t.txt", language: "plain")
        let engine = Recorder(budget: 3_000, reduceReply: { _ in "- Line 3 hides a secret.\n- Line 40 starts the list.\n- Lines 400-410 end it." })
        let req = Self.request(s, action: .summarise, budget: 3_000)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        #expect(plan.parts.contains { !$0.fits && $0.first == 3 })
        #expect(OwlChunkedReview.label(plan) == "Whole document (120 lines; 1 too long to read)")
        let result = await Self.run(req, plan, engine)
        #expect(result.outcome.answer.contains("Line 40 starts the list."))
        #expect(!result.outcome.answer.contains("hides a secret"))
        #expect(!result.outcome.answer.contains("400"))
        #expect(result.outcome.answer.contains("Line 3 was too long for this model and was not reviewed."))
    }

    @Test func anOrdinaryAnswerCitingUnsentLinesIsFiltered() async throws {
        let s = Self.doc282()
        // Shown lines 1–18 only, as the trimmed Summarise was.
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: (s.numbered(lines: 1, 18) as NSString).length)!
        #expect(ctx.firstLine == 1 && ctx.lastLine == 18)
        let reply = "- Line 3 sets the title.\n- Lines 12–14 describe the walk.\n- Lines 19–20 talk about rain.\n- Lines 31–34 end the day."
        let engine = Recorder(partReply: { _, _ in reply })
        let req = OwlChatRequest(question: "Summarise", action: .summarise, context: ctx, snapshot: s, useTools: false, prose: true)
        let outcome = try await OwlChatRunner.run(req, engine: engine) { _ in }
        #expect(outcome.answer.contains("Line 3 sets the title."))
        #expect(outcome.answer.contains("Lines 12–14 describe the walk."))
        #expect(!outcome.answer.contains("19") && !outcome.answer.contains("31"))
    }

    @Test func aFollowUpMayCiteLinesTheConversationNamed() async throws {
        let s = Self.doc282()
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: (s.numbered(lines: 1, 18) as NSString).length)!
        let history = [OwlChatEntry(role: .user, text: "Anything odd?"),
                       OwlChatEntry(role: .owl, text: "The note on line 210 repeats itself.")]
        let engine = Recorder(partReply: { _, _ in "- Line 210 repeats the walk.\n- Line 250 is new." })
        let req = OwlChatRequest(question: "Why is that a problem?", context: ctx, snapshot: s, history: history,
                                 useTools: false, prose: true)
        let outcome = try await OwlChatRunner.run(req, engine: engine) { _ in }
        #expect(outcome.answer.contains("- Line 210 repeats the walk."))
        #expect(!outcome.answer.contains("250"))
    }
}
