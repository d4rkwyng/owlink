import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Ask Cedric on a document shown in part (0.4.0): the digest (outline
/// with counts, matching lines) for a model without the tool gate's
/// trust, get_outline's counts for one with tools, the coverage note
/// before the answer, and none of it when the model saw everything.
@Suite struct OwlAskScopeAITests {
    static let doc: String = {
        var s = "# Games\n"
        for sys in ["NES", "SNES", "Genesis"] {
            s += "## \(sys)\n"
            for i in 1...60 { s += "- \(sys) game \(i)\n" }
        }
        return s
    }()   // 184 lines
    static func snap(visibleLines: Int = 20) -> OwlDocumentSnapshot {
        let ns = doc as NSString
        var end = 0
        for _ in 0..<visibleLines { end = NSMaxRange(ns.lineRange(for: NSRange(location: end, length: 0))) }
        return OwlDocumentSnapshot(text: doc, generation: 1, visible: NSRange(location: 0, length: end),
                                   fileName: "games.md", language: "markdown")
    }
    static func request(_ q: String = "How many games per system?", action: OwlQuickAction? = nil, scope: OwlChatScope = .visible,
                        useTools: Bool = false, budget: Int = 5_000) -> OwlChatRequest {
        let s = snap()
        let ctx = OwlChatContext.build(s, scope: scope, budget: budget)!
        return OwlChatRequest(question: q, action: action, context: ctx, snapshot: s, useTools: useTools, prose: true)
    }

    /// Records what it was offered and its prompt, makes `call` once if offered tools, then answers.
    final class Probe: OwlChatEngine, @unchecked Sendable {
        var title: String { "probe" }; var scoreKey: String { "probe" }; var contextBudget: Int { 5_000 }
        var offered: [[String]] = []
        var system = ""
        var user = ""
        let call: OwlToolCall?
        init(call: OwlToolCall? = OwlToolCall(name: "get_outline")) { self.call = call }
        func turn(_ m: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            offered.append(tools.map(\.name.rawValue))
            if case .system(let s)? = m.first { system = s }
            if offered.count == 1, case .user(let u)? = m.last { user = u }
            if let call, !tools.isEmpty, offered.count == 1 { return .toolCalls([call]) }
            onText("Each has 60.")
            return .answer("Each has 60.")
        }
    }

    @Test func toolsAreUnchangedTheDigestIsTheUngatedPath() {
        // No tools without the gate's trust (the digest instead); the full set with it.
        #expect(Self.request().tools.isEmpty)
        #expect(Self.request(useTools: true).tools.contains(.getOutline))
        let sys = OwlPrompts.chatSystem(toolsOn: false, digest: true)
        #expect(sys.contains("count from the outline") && sys.contains("Never answer as if you had seen lines you haven't"))
        // Without a digest the prompts are what the tool eval measured.
        #expect(!OwlPrompts.chatSystem(toolsOn: false).contains("outline"))
        #expect(OwlPrompts.chatSystem(toolsOn: true, digest: true) == OwlPrompts.chatSystem(toolsOn: true))
    }

    @Test func coverageNoteSaysWhatWasSeen() {
        let r = Self.request()
        #expect(r.coverageNote() == "I can see lines 1–20 of 184.")
        #expect(r.coverageNote(linesRead: IndexSet(integersIn: 100...120), looks: [.getOutline])
                == "I can see lines 1–20 and 100–120 of 184, plus the outline and counts of the whole file.")
        #expect(r.coverageNote(linesRead: IndexSet(integersIn: 21...184)) == nil)
        #expect(Self.request(scope: .wholeDocument, budget: 50_000).coverageNote() == nil)
        #expect(Self.request("Explain", action: .explain).coverageNote() == nil)
        // A pure sum has no note. General knowledge keeps it (France is not in this file).
        // A question that only points at the document keeps it.
        #expect(Self.request("What is 12 times 7?").coverageNote() == nil)
        #expect(Self.request("3+4*2").coverageNote() == nil)
        #expect(Self.request("What is the capital of France?").coverageNote() == "I can see lines 1–20 of 184.")
        #expect(Self.request("What's this about?").coverageNote() == "I can see lines 1–20 of 184.")
        #expect(Self.request("Explain this.").coverageNote() == "I can see lines 1–20 of 184.")
        #expect(Self.request("What does it say about multiplayer?").coverageNote() == "I can see lines 1–20 of 184.")
        // The whole document asked for but trimmed to the budget: said too.
        let trimmed = Self.request(scope: .visible, budget: 200)
        #expect(trimmed.coverageNote()?.hasPrefix("I can see lines 1–") == true)
    }

    @Test func ungatedRunnerSendsTheDigestAndSaysCoverageFirst() async throws {
        let probe = Probe()
        let events = TextBuffer()
        let o = try await OwlChatRunner.run(Self.request("How many games for Genesis?"), engine: probe) { e in if case .text(let t) = e { events.append(t) } }
        #expect(probe.offered == [[]])
        #expect(probe.system.contains("count from the outline"))
        #expect(probe.user.contains("OUTLINE OF THE WHOLE DOCUMENT") && probe.user.contains("124| ## Genesis"))
        #expect(probe.user.hasSuffix("How many games for Genesis?"))
        // Shown 1-20; the digest showed 119-129 and the outline.
        let note = "I can see lines 1–20 and 119–129 of 184, plus the outline and counts of the whole file."
        #expect(o.answer == note + "\n\nEach has 60.")
        #expect(events.value == o.answer)
        #expect(o.coverageNote == note && o.modelAnswer == "Each has 60.")
    }

    @Test func gatedRunnerCountsTheToolsItUsed() async throws {
        let probe = Probe(call: OwlToolCall(name: "get_lines", arguments: .object(["start": .number(21), "end": .number(40)])))
        let o = try await OwlChatRunner.run(Self.request(useTools: true), engine: probe) { _ in }
        #expect(probe.offered.first?.contains("get_outline") == true)
        #expect(!probe.user.contains("OUTLINE OF THE WHOLE DOCUMENT"))
        #expect(o.coverageNote == "I can see lines 1–40 of 184.")
        let outlined = try await OwlChatRunner.run(Self.request(useTools: true), engine: Probe()) { _ in }
        #expect(outlined.coverageNote == "I can see lines 1–20 of 184, plus the outline and counts of the whole file.")
    }

    /// The small model's digest: the outline with counts, and the
    /// section matching the question's words, inside the budget.
    @Test func digestGivesTheOutlineAndTheMatchingSection() {
        let d = Self.request("What is in the Genesis section?").digest(budget: 2_000)!
        #expect(d.hasOutline)
        #expect(d.text.contains("OUTLINE OF THE WHOLE DOCUMENT (184 lines"))
        #expect(d.text.contains("Total in all 184 lines: 180 list items, 0 table rows"))
        #expect(d.text.contains("63| ## SNES [60 list items]"))
        // "genesis" matches line 124's heading: its section is 61 lines, too long, so lines around it.
        #expect(d.lines == IndexSet(integersIn: 119...129))
        #expect(d.text.contains("124| ## Genesis"))
        #expect((d.text as NSString).length <= 2_000)
        // Tight budget: no room, no digest parts that don't fit.
        #expect(Self.request().digest(budget: 100) == nil)
        // A gated model and a quick action get none (tools / their scope).
        #expect(Self.request(useTools: true).digest(budget: 2_000) == nil)
        #expect(Self.request("Explain", action: .explain).digest(budget: 2_000) == nil)
    }

    @Test func wholeDocumentAnswerHasNoNote() async throws {
        let probe = Probe()
        let o = try await OwlChatRunner.run(Self.request(scope: .wholeDocument, budget: 50_000), engine: probe) { _ in }
        #expect(o.answer == "Each has 60." && o.coverageNote == nil && o.modelAnswer == o.answer)
        #expect(probe.offered == [[]])
    }

    @Test func promptsDescribeActualCoverage() throws {
        let s = OwlDocumentSnapshot(text: "print('hello')\nprint('world')\n", generation: 1,
                                    visible: NSRange(location: 0, length: 5), language: "python")
        for scope in [OwlChatScope.wholeDocument, .visible] {
            let ctx = try #require(OwlChatContext.build(s, scope: scope, budget: 5_000))
            let partial = scope == .visible
            let req = OwlChatRequest(question: "Check risks", action: .scriptSafety, context: ctx, snapshot: s,
                                     useTools: true, prose: false)
            let messages = OwlPrompts.chatMessages(question: req.prompt, context: ctx, language: "Python", fileName: nil,
                                                   history: [], toolsOn: true, model: "", totalLines: s.countedLines)
            guard case .system(let system)? = messages.first, case .user(let user)? = messages.last else {
                Issue.record("Expected system and user messages"); return
            }
            #expect(system.contains("You usually see only part of the document") == partial)
            #expect(req.prompt.contains("lines 1-1 of 2") == partial)
            #expect(user.contains("You see lines 1-1 of 2") == partial)
            #expect(user.contains(" of 2") == partial)
            #expect(req.forcedVerdict == (partial ? .truncated : nil))
            #expect(!OwlPrompts.envelopeInstructions(OwlTools.specs(req.tools)).contains("You were shown only some lines"))
            if !partial {
                #expect(!user.contains("(trimmed;"))
                #expect(!req.contextIsPartial)
                var scanTruncated = req
                scanTruncated.scanTruncated = true
                #expect(scanTruncated.forcedVerdict == .truncated)
            }
        }
        let trimmed = try #require(OwlChatContext.build(s, scope: .wholeDocument, budget: 15))
        let req = OwlChatRequest(question: "Check risks", action: .scriptSafety, context: trimmed, snapshot: s,
                                 useTools: false, prose: false)
        #expect(req.prompt.contains("lines 1-1 of 2"))
        #expect(req.forcedVerdict == .truncated)
    }

    @Test func documentContextReservesTheActualPromptAndDigest() throws {
        let s = Self.snap()
        let history = [OwlChatEntry(role: .user, text: String(repeating: "h", count: 300))]
        let question = "What is in the Genesis section?"
        let ctx = try #require(OwlChatRequest.documentContext(s, scope: .wholeDocument, engineBudget: 5_000,
                                                              history: history, question: question, action: nil,
                                                              tools: false, server: false, prose: true))
        let req = OwlChatRequest(question: question, context: ctx, snapshot: s, history: history, useTools: false, prose: true)
        let additions = req.contextAdditions(engineBudget: 5_000)
        #expect(ctx.truncated && additions.digest != nil && additions.digestReservation > 0)
        #expect((ctx.numbered as NSString).length <= req.documentBudget(engineBudget: 5_000, server: false))

        let preview = try #require(OwlChatRequest.documentContext(s, scope: .wholeDocument, engineBudget: 5_000,
                                                                  history: history, question: question, action: nil,
                                                                  tools: false, server: false, prose: true, preview: true))
        #expect((preview.numbered as NSString).length >= (ctx.numbered as NSString).length)
        let action = try #require(OwlChatRequest.documentContext(s, scope: .wholeDocument, engineBudget: 5_000,
                                                                 history: history, question: "Check risks",
                                                                 action: .scriptSafety, tools: false, server: false,
                                                                 prose: false, scan: String(repeating: "finding ", count: 100)))
        let actionReq = OwlChatRequest(question: "Check risks", action: .scriptSafety, context: action, snapshot: s,
                                       history: history, useTools: false, prose: false,
                                       scan: String(repeating: "finding ", count: 100))
        #expect((action.numbered as NSString).length <= actionReq.documentBudget(engineBudget: 5_000, server: false))
    }

    @Test func largeScriptDocumentContextFitsTheRemainingBudget() throws {
        let text = (1...263).map { i in
            let prefix = "line-\(i) "
            return prefix + String(repeating: "x", count: (i <= 52 ? 36 : 35) - prefix.count)
        }.joined(separator: "\n")
        #expect((text as NSString).length == 9_519)
        let ns = text as NSString
        let caret = ns.range(of: "line-132 ").location
        let visibleEnd = ns.range(of: "line-53 ").location
        let s = OwlDocumentSnapshot(text: text, generation: 1, selection: NSRange(location: caret, length: 0),
                                    visible: NSRange(location: 0, length: visibleEnd), language: "python")
        let typed = try #require(OwlChatRequest.documentContext(s, scope: .wholeDocument, engineBudget: 5_000,
                                                                history: [], question: "What does this script do?",
                                                                action: nil, tools: false, server: false, prose: false))
        #expect(typed.truncated && typed.numbered.contains("line-132 "))
        let typedReq = OwlChatRequest(question: "What does this script do?", context: typed, snapshot: s,
                                      useTools: false, prose: false)
        #expect((typed.numbered as NSString).length <= typedReq.documentBudget(engineBudget: 5_000, server: false))
        #expect(typedReq.contextIsPartial && typedReq.forcedVerdict == nil)
        #expect(typed.label.hasSuffix("of 263 (trimmed to fit)"))

        let safety = try #require(OwlChatRequest.documentContext(s, scope: .wholeDocument, engineBudget: 5_000,
                                                                 history: [], question: "Check risks",
                                                                 action: .scriptSafety, tools: false, server: false,
                                                                 prose: false))
        #expect(safety.truncated && safety.numbered.contains("line-132 "))
        let safetyReq = OwlChatRequest(question: "Check risks", action: .scriptSafety, context: safety, snapshot: s,
                                       useTools: false, prose: false)
        #expect((safety.numbered as NSString).length <= safetyReq.documentBudget(engineBudget: 5_000, server: false))
        #expect(safetyReq.forcedVerdict == .truncated)
        #expect(safety.lastLine - safety.firstLine + 1 > 0)
    }
}
