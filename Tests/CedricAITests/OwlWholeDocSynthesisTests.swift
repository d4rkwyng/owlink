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

    /// The first line `text` cites (1 if none): a merge reply that cites only what it was given.
    static func firstCited(_ text: String) -> Int {
        OwlCitations.evidence(in: text.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.joined(separator: "\n")).first ?? 1
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
            // A merge returns a shorter note that cites a line it was shown.
            // (One that never shortens fails honestly: see below.)
            let engine = Recorder(budget: budget, partReply: long,
                                  reduceReply: { u in u.contains(OwlChunkedReviewRunner.notesLabel) ? "Combined."
                                      : "- Line \(Self.firstCited(u)): merged " + String(repeating: "m", count: 400) })
            let req = Self.request(Self.doc282(), action: .summarise, budget: budget)
            let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
            let result = await Self.run(req, plan, engine)
            #expect(result.error == nil && !result.stopped, "budget \(budget): \(result.error ?? "")")
            #expect(engine.reduceCalls.count > 1, "the notes were merged in groups first (budget \(budget))")
            for call in engine.calls { #expect(Self.size(call) <= budget, "budget \(budget)") }
            #expect(result.outcome.answer == "Combined.")
        }
    }

    @Test func aLongBacktickRunInTheNotesStillFitsEveryCall() async throws {
        // Each note holds a 300-backtick run: the data fence grows to 301 on each side.
        let ticks: @Sendable (Int, Int) -> String = { a, b in
            "- Line \(a): " + String(repeating: "`", count: 300) + "\n"
                + (a...min(b, a + 8)).map { "- Line \($0): " + String(repeating: "note ", count: 30) }.joined(separator: "\n")
        }
        for budget in [5_000, 3_600] {
            let engine = Recorder(budget: budget, partReply: ticks,
                                  reduceReply: { u in u.contains(OwlChunkedReviewRunner.notesLabel) ? "Combined."
                                      : "- Line \(Self.firstCited(u)): merged." })
            let req = Self.request(Self.doc282(), action: .summarise, budget: budget)
            let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
            let result = await Self.run(req, plan, engine)
            #expect(result.error == nil && result.outcome.answer == "Combined.", "budget \(budget)")
            #expect(engine.reduceCalls.contains { Recorder.user($0).contains(String(repeating: "`", count: 301)) })
            for call in engine.calls { #expect(Self.size(call) <= budget, "budget \(budget)") }
        }
    }

    @Test func aNoteLongerThanOneCallIsSplitNotClipped() async throws {
        // Every part's note is longer than one merge call can hold, and its
        // last finding is at its very end.
        let long: @Sendable (Int, Int) -> String = { a, b in
            (0..<40).map { _ in "- Line \(a): " + String(repeating: "filler ", count: 25) }.joined(separator: "\n")
                + "\n- Line \(b): TAIL-\(b)"
        }
        // A merge keeps the TAIL findings it was given (and one line otherwise).
        let merge: @Sendable (String) -> String = { u in
            if u.contains(OwlChunkedReviewRunner.notesLabel) { return "Combined." }
            let tails = u.components(separatedBy: "\n").filter { $0.contains("TAIL-") && $0.hasPrefix("- ") }
            return tails.isEmpty ? "- Line \(Self.firstCited(u)): filler." : tails.joined(separator: "\n")
        }
        let budget = 3_600
        let engine = Recorder(budget: budget, partReply: long, reduceReply: merge)
        let req = Self.request(Self.doc282(), action: .summarise, budget: budget)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await Self.run(req, plan, engine)
        #expect(result.error == nil && result.outcome.answer == "Combined.")
        for call in engine.calls { #expect(Self.size(call) <= budget) }
        // Every part's last finding reached the final call.
        let final = Recorder.user(engine.reduceCalls.last!)
        for part in plan.parts { #expect(final.contains("TAIL-\(part.last)"), "part \(part.first)–\(part.last)") }
    }

    @Test func splittingANoteNeverTurnsAFlaggedCitationIntoEvidence() async throws {
        // Each part's note has one paragraph longer than a merge call, full
        // of a citation of line 9999 that the part filter flagged as unread.
        // Wherever the splitter cuts, no piece may vouch for 9999.
        for pad in [0, 11] {
            let part: @Sendable (Int, Int) -> String = { a, _ in
                "- Line \(a): opens.\nOverview of line \(a): " + String(repeating: "x", count: pad)
                    + String(repeating: "and line 9999 here, ", count: 160)
            }
            // A merge invents line 9999; it stands only if its notes vouch for it.
            let merge: @Sendable (String) -> String = { u in
                u.contains(OwlChunkedReviewRunner.notesLabel) ? "Combined."
                    : "- Line \(Self.firstCited(u)): merged.\n- Line 9999: invented."
            }
            let engine = Recorder(budget: 3_600, partReply: part, reduceReply: merge)
            let req = Self.request(Self.doc282(), action: .summarise, budget: 3_600)
            let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
            let result = await Self.run(req, plan, engine)
            #expect(engine.reduceCalls.count > 1, "pad \(pad)")
            for call in engine.reduceCalls {
                #expect(!Recorder.user(call).contains("9999: invented"), "pad \(pad)")
            }
            #expect(!result.outcome.answer.contains("invented"), "pad \(pad)")
        }
    }

    @Test func anOversizedLineIsCutOnlyWhereNoCitationGainsEvidence() {
        let flagged = "Line 999\(OwlCitations.flag)"
        let line = "Line 4 says " + String(repeating: "\(flagged) again, ", count: 20)
        // A piece holds at least one whole flagged citation (35 characters).
        for limit in 35...70 {
            let pieces = OwlChunkedReviewRunner.splitLine(line, fits: { ($0 as NSString).length <= limit })
            guard let got = pieces else { Issue.record("no split at limit \(limit)"); continue }
            #expect(got.joined() == line, "limit \(limit)")
            for p in got {
                #expect(OwlCitations.evidence(in: p).isSubset(of: IndexSet(integer: 4)), "limit \(limit): \(p)")
                // Never "Line" / "999 (not among …)" or "Line 999" / " (not among …)".
                #expect(!p.hasSuffix("Line ") && !p.hasSuffix("999") && !p.hasPrefix(" ("), "limit \(limit): \(p)")
            }
        }
        // Shorter than that, no piece can hold one whole: no split, not a cut inside it.
        #expect(OwlChunkedReviewRunner.splitLine(line, fits: { ($0 as NSString).length <= 30 }) == nil)
    }

    @Test func notesThatNeverShortenFailHonestlyAndKeepTheNotes() async throws {
        let long: @Sendable (Int, Int) -> String = { a, b in
            (a...min(b, a + 11)).map { "- Line \($0): " + String(repeating: "detail ", count: 22) }.joined(separator: "\n")
        }
        // A merge that only ever grows its notes.
        let engine = Recorder(budget: 3_600, partReply: long,
                              reduceReply: { u in "- Line \(Self.firstCited(u)): " + String(repeating: "grown ", count: 2_000) })
        let req = Self.request(Self.doc282(), action: .summarise, budget: 3_600)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await Self.run(req, plan, engine)
        #expect(result.error == "The notes could not be combined into one answer within this model’s context.")
        #expect(result.outcome.answer.contains("not combined into one answer"))
        #expect(result.outcome.sections.count == plan.parts.count)
        for call in engine.calls { #expect(Self.size(call) <= 3_600) }
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

    @Test func findProblemsIsSynthesizedFromTheMergedFindingsAndDropsNone() async throws {
        // The combine call mentions only the first finding.
        let engine = Recorder(partReply: { a, _ in "- Line \(a + 1): a real problem." },
                              reduceReply: { _ in "The main problem is on line 2." })
        let req = Self.request(Self.doc282(), action: .findProblems)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await Self.run(req, plan, engine)
        #expect(result.error == nil && !result.stopped)
        // One synthesized answer first, the parts' notes below.
        #expect(engine.reduceCalls.count == 1 && result.reduceCalls == 1)
        #expect(result.outcome.answer.hasPrefix("The main problem is on line 2."))
        #expect(result.outcome.sections.count == plan.parts.count)
        // The merged findings went into the combine call as its notes …
        let final = Recorder.user(engine.reduceCalls[0])
        for part in plan.parts { #expect(final.contains("Line \(part.first + 1): a real problem.")) }
        // … and none is dropped from the answer, each once.
        for part in plan.parts where part.first + 1 != 2 {
            #expect(result.outcome.answer.components(separatedBy: "Line \(part.first + 1): a real problem.").count == 2)
        }
        // No tools in the combine call.
        #expect(engine.reduceCalls.allSatisfy { m in !m.contains { if case .toolCalls = $0 { return true }; return false } })
    }

    @Test func aFindingWhoseLineIsCitedForSomethingElseIsStillKept() {
        let items = "- Line 12: downloads unsigned code.\n- Line 40: writes /etc/hosts\n  without asking first.\n"
            + "- The installer never verifies a checksum.\n  It trusts any mirror."
        let findings = OwlChunkedReviewRunner.Findings(text: items, items: items, verdict: nil)
        // Same line, different claim: the risk on line 12 is not in the answer.
        let answer = "Line 12 starts the setup. Line 40 writes /etc/hosts without asking first."
        let kept = OwlChunkedReviewRunner.keepFindings(answer, findings)
        #expect(kept.hasPrefix(answer))
        #expect(kept.contains("- Line 12: downloads unsigned code."))
        // The line-40 finding is in the answer in substance: not repeated.
        #expect(!kept.contains("- Line 40"))
        // An uncited finding the answer left out comes back with its continuation row.
        #expect(kept.contains("- The installer never verifies a checksum.\n  It trusts any mirror."))
        // An answer that keeps every finding (in its own words) gets nothing added.
        let full = "Line 12 downloads code that is unsigned. Line 40 writes /etc/hosts without asking. "
            + "The installer never verifies a checksum and trusts any mirror."
        #expect(OwlChunkedReviewRunner.keepFindings(full, findings) == full)
    }

    @Test func aFindingWhoseMeaningTheAnswerReversesIsStillKept() {
        let items = "- Line 12: downloads unsigned code."
        let findings = OwlChunkedReviewRunner.Findings(text: items, items: items, verdict: nil)
        // Same line, most of the same words, the opposite claim.
        for answer in ["Line 12 downloads signed code.", "Line 12 doesn\u{2019}t download unsigned code.",
                       "Line 12 never downloads unsigned code."] {
            let kept = OwlChunkedReviewRunner.keepFindings(answer, findings)
            #expect(kept.hasPrefix(answer) && kept.hasSuffix(items), "\(answer)")
        }
        // The same claim in other words still keeps it.
        let same = "Line 12 downloads code that is unsigned."
        #expect(OwlChunkedReviewRunner.keepFindings(same, findings) == same)
        // A negated finding needs the answer to say no too.
        let negated = "- Line 7: never checks the checksum."
        let neg = OwlChunkedReviewRunner.Findings(text: negated, items: negated, verdict: nil)
        #expect(OwlChunkedReviewRunner.keepFindings("Line 7 checks the checksum.", neg).hasSuffix(negated))
        let alsoNegated = "Line 7 never checks the checksum."
        #expect(OwlChunkedReviewRunner.keepFindings(alsoNegated, neg) == alsoNegated)
    }

    @Test func aNoteIsNeverCutInsideACitationThatSpansRows() {
        // The whole note flags 4–9999 as unread: no evidence for line 4.
        let note = "Overview of the part.\nLine 4 through\n9999\(OwlCitations.flag)| quoted text.\nThe end."
        #expect(OwlCitations.evidence(in: note).isEmpty)
        let flagNextRow = "Overview.\nLine 4\n\(OwlCitations.flag.trimmingCharacters(in: .whitespaces)) and more."
        for text in [note, note.replacingOccurrences(of: "through", with: "to"),
                     note.replacingOccurrences(of: " through", with: " -"), flagNextRow] {
            let whole = OwlCitations.evidence(in: text)
            for limit in 10...(text as NSString).length {
                guard let pieces = OwlChunkedReviewRunner.splitNote(text, fits: { ($0 as NSString).length <= limit }) else {
                    continue
                }
                for p in pieces {
                    #expect(OwlCitations.evidence(in: p).isSubset(of: whole), "limit \(limit): \(p)")
                }
            }
        }
        // Cut at rows where it's safe: "Line 4 through" stays with "9999".
        let got = OwlChunkedReviewRunner.splitNote(note, fits: { ($0 as NSString).length <= 70 })
        #expect(got == ["Overview of the part.", "Line 4 through\n9999\(OwlCitations.flag)| quoted text.\nThe end."])
    }

    /// "Line 4 through" / "18 describes the setup": cut there, the first
    /// piece cites line 4 alone, a citation the whole note never made (its
    /// evidence, {4}, is inside 4–18, so 0.5.3's follow-up allowed the cut).
    @Test func aNoteIsNeverCutInsideACitationEvenWhereEvidenceShrinks() {
        let flagged = "Line 999\(OwlCitations.flag)"
        for text in ["Line 4 through\n18 describes the setup.", "Line 4 through 18 describes the setup.",
                     "Lines 4 and\n9 describe the setup.", "Overview.\nLine 4 -\r\n18 describes it.",
                     "Overview. \(flagged) describes it."] {
            let whole = OwlCitations.find(text).map(\.lines)
            for limit in 1...(text as NSString).length {
                guard let pieces = OwlChunkedReviewRunner.splitNote(text, fits: { ($0 as NSString).length <= limit }) else {
                    continue
                }
                for p in pieces {
                    // Each citation a piece reads is one of the note's, whole.
                    for c in OwlCitations.find(p) {
                        #expect(whole.contains(c.lines), "limit \(limit): \(p.debugDescription)")
                    }
                    // A flagged citation keeps its flag.
                    #expect(!p.hasSuffix("999") && !p.hasPrefix(" ("), "limit \(limit): \(p.debugDescription)")
                }
            }
        }
        // The citation's own row stays whole; the rest of the note is cut as before.
        let got = OwlChunkedReviewRunner.splitNote("Line 4 through\n18 describes the setup.", fits: { ($0 as NSString).length <= 30 })
        #expect(got == ["Line 4 through\n18 describes ", "the setup."])
        let rows = OwlChunkedReviewRunner.splitNote("Overview.\nLine 4 through\n18 describes it.\nThe end.",
                                                    fits: { ($0 as NSString).length <= 31 })
        #expect(rows == ["Overview.", "Line 4 through\n18 describes it.", "The end."])
    }

    /// "Line 12: the token expires after 90 days" doesn't keep "Line 12:
    /// the token expires after 30 days": the number is what it says.
    @Test func aFindingWhoseNumberTheAnswerChangesIsStillKept() {
        let items = "- Line 12: the token expires after 30 days."
        let findings = OwlChunkedReviewRunner.Findings(text: items, items: items, verdict: nil)
        let changed = "Line 12: the token expires after 90 days."
        let kept = OwlChunkedReviewRunner.keepFindings(changed, findings)
        #expect(kept.hasPrefix(changed) && kept.hasSuffix(items))
        // The same number, in other words, keeps it; the line numbers cited aren't content.
        let same = "Lines 12–13: after 30 days the token expires."
        #expect(OwlChunkedReviewRunner.keepFindings(same, findings) == same)
        let uncited = "- Retries 3 times before giving up."
        let u = OwlChunkedReviewRunner.Findings(text: uncited, items: uncited, verdict: nil)
        #expect(OwlChunkedReviewRunner.keepFindings("It retries 5 times before giving up.", u).hasSuffix(uncited))
    }

    @Test func checkForRisksKeepsTheMostCautiousVerdictThroughSynthesis() async throws {
        let dontRun = "Verdict: \(ScriptVerdict.dontRun)."
        // One part says don't run; the others trust the source; the combine call softens it.
        let engine = Recorder(partReply: { a, _ in
            "- Line \(a): downloads code.\n" + (a == 1 ? dontRun : "Verdict: \(ScriptVerdict.trustSource).")
        }, reduceReply: { _ in "It downloads code on line 1.\nVerdict: \(ScriptVerdict.noRedFlags)." })
        let req = Self.request(Self.doc282(), action: .scriptSafety)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        let result = await Self.run(req, plan, engine)
        #expect(engine.reduceCalls.count == 1)
        // The worst verdict went in, once …
        let notes = Recorder.user(engine.reduceCalls[0]).components(separatedBy: OwlChunkedReviewRunner.notesLabel).last!
        #expect(notes.contains(dontRun) && !notes.contains("Verdict: \(ScriptVerdict.trustSource)"))
        // … and comes out: the answer's own softer verdict does not stand.
        let answer = result.outcome.answer
        #expect(answer.hasPrefix("It downloads code on line 1."))
        #expect(answer.hasSuffix(dontRun))
        #expect(!answer.contains(ScriptVerdict.noRedFlags))
        for part in plan.parts { #expect(answer.contains("Line \(part.first): downloads code.") || part.first == 1) }
        #expect(result.outcome.sections.count == plan.parts.count)
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
        let req = Self.request(s, action: .summarise, budget: 3_000)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: Recorder(budget: 3_000)))
        #expect(plan.parts.contains { !$0.fits && $0.first == 3 })
        #expect(OwlChunkedReview.label(plan) == "Whole document (120 lines; 1 too long to read)")
        // The notes cite each part's first and last line only; an interior
        // line was read by a part but neither its text nor number is in them.
        let part = try #require(plan.parts.first { $0.fits && $0.last - $0.first >= 2 && $0.first > 3 })
        let interior = part.first + 1
        let reply = "- Line 3 hides a secret.\n- Line \(part.first) starts the list.\n- Line \(interior) is in the middle.\n- Lines 400-410 end it."
        let engine = Recorder(budget: 3_000, reduceReply: { _ in reply })
        let result = await Self.run(req, plan, engine)
        #expect(result.outcome.answer.contains("Line \(part.first) starts the list."))
        #expect(!result.outcome.answer.contains("in the middle"))
        #expect(!result.outcome.answer.contains("hides a secret"))
        #expect(!result.outcome.answer.contains("400"))
        #expect(result.outcome.answer.contains("Line 3 was too long for this model and was not reviewed."))
    }

    @Test func theCombinedAnswerMayCiteLinesTheConversationSentWithItNamed() async throws {
        let history = [OwlChatEntry(role: .user, text: "Anything odd?"),
                       OwlChatEntry(role: .owl, text: "The note on line 150 repeats itself.")]
        let engine = Recorder(reduceReply: { _ in "- Line 150 repeats the walk.\n- Line 151 is new.\n- Line 1 opens it." })
        let req = Self.request(Self.doc282(), action: nil, question: "Why does it repeat?", history: history)
        let plan = try #require(OwlChunkedReviewRunner.plan(req, engine: engine))
        #expect(!plan.parts.contains { $0.first == 151 || $0.last == 151 })
        let result = await Self.run(req, plan, engine)
        // Sent with the final call: the conversation's line 150 is citable, 151 is not.
        #expect(engine.reduceCalls.last!.contains(.assistant("The note on line 150 repeats itself.")))
        #expect(result.outcome.answer.contains("- Line 150 repeats the walk."))
        #expect(!result.outcome.answer.contains("151"))
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

    /// Searches once (with `query`) when offered tools, then answers `reply`.
    final class Searcher: OwlChatEngine, @unchecked Sendable {
        var title: String { "searcher" }; var scoreKey: String { "searcher" }; var contextBudget: Int { 5_000 }
        let query: String, reply: String
        private let lock = NSLock()
        private var searched = false
        init(query: String, reply: String) { self.query = query; self.reply = reply }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            let first = lock.withLock { () -> Bool in defer { searched = true }; return !searched }
            if first, tools.contains(where: { $0.name == .searchDocument }) {
                return .toolCalls([OwlToolCall(name: "search_document", arguments: .object(["query": .string(query)]))])
            }
            onText(reply)
            return .answer(reply)
        }
    }

    @Test func aSearchKeepsTheCitationFilterOnToTheLinesItShowed() async throws {
        let s = Self.doc282()
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: (s.numbered(lines: 1, 18) as NSString).length)!
        // The 282-line document has "Note 200:" on line 205 (four front-matter lines, plus headings).
        let target = try #require(s.text.components(separatedBy: "\n").firstIndex { $0.hasPrefix("Note 200:") }) + 1
        let reply = "- Line 3 sets the title.\n- Line \(target) is the match.\n- Line 250 is new."
        for (query, matched) in [("zz-no-such-text", false), ("Note 200:", true)] {
            let engine = Searcher(query: query, reply: reply)
            let req = OwlChatRequest(question: "Where is note 200?", context: ctx, snapshot: s, useTools: true, prose: true)
            try #require(req.tools.contains(.searchDocument))
            let outcome = try await OwlChatRunner.run(req, engine: engine) { _ in }
            #expect(outcome.toolCalls == 1)
            #expect(outcome.answer.contains("- Line 3 sets the title."))
            // A search that found nothing vouches for no line; one that found it, for that line only.
            #expect(outcome.answer.contains("Line \(target) is the match.") == matched, "query \(query)")
            #expect(!outcome.answer.contains("250"), "query \(query)")
        }
    }

    /// Streams `reply` a few characters at a time.
    final class Trickle: OwlChatEngine, @unchecked Sendable {
        var title: String { "trickle" }; var scoreKey: String { "trickle" }; var contextBudget: Int { 5_000 }
        let reply: String
        init(_ reply: String) { self.reply = reply }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            var i = reply.startIndex
            while i < reply.endIndex {
                let j = reply.index(i, offsetBy: 4, limitedBy: reply.endIndex) ?? reply.endIndex
                onText(String(reply[i..<j]))
                i = j
            }
            return .answer(reply)
        }
    }

    @Test func anOrdinaryAnswerNeverStreamsAnUncheckedCitation() async throws {
        let s = Self.doc282()
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: (s.numbered(lines: 1, 18) as NSString).length)!
        let reply = "Overview first.\n- Line 3 sets the title.\n- Lines 19–20 talk about rain.\nThe end on line 31 matters."
        let req = OwlChatRequest(question: "Summarise", action: .summarise, context: ctx, snapshot: s, useTools: false, prose: true)
        let texts = Box<[String]>([])
        let outcome = try await OwlChatRunner.run(req, engine: Trickle(reply)) { e in
            if case .text(let t) = e { texts.mutate { $0.append(t) } }
        }
        let shown = texts.value.joined()
        // What the panel showed (and would keep on Stop): 19–20 and 31 only ever flagged.
        #expect(shown.contains("- Line 3 sets the title."))
        #expect(shown.contains("Lines 19–20\(OwlCitations.flag)") && shown.contains("line 31\(OwlCitations.flag)"))
        #expect(!shown.contains("19–20 talk") && !shown.contains("31 matters"))
        // The finished answer drops the unread list item entirely.
        #expect(!outcome.answer.contains("rain") && outcome.answer.contains("line 31\(OwlCitations.flag)"))
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
