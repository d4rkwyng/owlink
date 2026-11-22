import Foundation
import Testing
import CedricCore
@testable import CedricAI

@Suite struct OwlInlineAssistTests {
    @Test func selectionAndEngineGating() {
        let gate = OwlToolGate(scores: ["weak": 0.79, "threshold": 0.8, "qwen": 0.879])
        func explain(_ enabled: Bool = true, _ ready: Bool = true, _ selected: Bool = true) -> Bool {
            OwlInlineAssist.canExplain(askEnabled: enabled, engineReady: ready, hasSelection: selected)
        }
        func rewrite(_ key: String, _ enabled: Bool = true, _ ready: Bool = true, _ selected: Bool = true) -> Bool {
            OwlInlineAssist.canRewrite(askEnabled: enabled, engineReady: ready, hasSelection: selected,
                                       allowsTools: gate.allowsTools(key))
        }
        #expect(explain())
        #expect(!explain(false) && !explain(true, false) && !explain(true, true, false))
        #expect(!rewrite("weak") && !rewrite("unmeasured"))
        #expect(rewrite("threshold") && rewrite("qwen"))
        #expect(!rewrite("qwen", false) && !rewrite("qwen", true, false) && !rewrite("qwen", true, true, false))
        #expect(explain() && !rewrite("weak"))
    }

    @Test func exactSelectionIsInTheRealQuickActionPrompt() throws {
        let text = "Before selected words after\nNext line"
        let range = (text as NSString).range(of: "selected words")
        let snapshot = OwlDocumentSnapshot(text: text, generation: 1, selection: range, language: "markdown")
        let context = try #require(OwlChatContext.build(snapshot, scope: .selection, budget: 5000))
        let explain = OwlChatRequest(question: "Explain Selection", action: .explain, context: context, snapshot: snapshot,
                                     useTools: false, prose: true, inlineSelection: "selected words")
        let rewrite = OwlChatRequest(question: "Rewrite Selection", action: .rewrite, context: context, snapshot: snapshot,
                                     useTools: true, prose: true, inlineSelection: "selected words")
        #expect(explain.prompt.contains("selected words") && !explain.prompt.contains("propose_edit"))
        #expect(rewrite.prompt.contains("selected words") && rewrite.prompt.contains("propose_edit"))
        #expect(rewrite.prompt.contains("find") && rewrite.prompt.contains("replace"))
        #expect(rewrite.tools.contains(.proposeEdit))
    }

    @Test func anchoredSelectionAndSkip() throws {
        let text = "Before selected words after"
        let selected = "selected words"
        let range = (text as NSString).range(of: selected)
        let snapshot = OwlDocumentSnapshot(text: text, generation: 1, selection: range)
        let proposal = try OwlEditProposal.anchored(find: selected, replace: "clear words", in: snapshot).get()
        #expect(proposal.state(text: text as NSString, generation: 1) == .ready(range))
        #expect((text as NSString).replacingCharacters(in: range, with: proposal.replacement) == "Before clear words after")
        let duplicate = OwlDocumentSnapshot(text: text + " " + selected, generation: 1)
        #expect(OwlEditProposal.anchored(find: selected, replace: "clear words", in: duplicate) == .failure(.notUnique))
        let entry = OwlChatEntry(role: .owl, text: "", proposals: [proposal])
        #expect(entry.proposals.count == 1)
        #expect(snapshot.text == text)
    }

    @Test func toolRejectsEditsOutsideTheExactSelection() throws {
        let text = "Before selected words after"
        let selection = "selected words"
        let range = (text as NSString).range(of: selection)
        let snapshot = OwlDocumentSnapshot(text: text, generation: 1, selection: range)
        let tools = OwlToolbox(snapshot: snapshot, allowed: [.proposeEdit], inlineSelection: selection)
        func edit(_ find: String) -> OwlToolResult {
            tools.run(OwlToolCall(name: "propose_edit", arguments: .object([
                "find": .string(find), "replace": .string("changed"), "reason": .string("clearer")
            ])))
        }
        #expect(!edit("Before").ok)
        #expect(!edit("selected").ok)
        let accepted = edit(selection)
        #expect(accepted.ok && accepted.proposal?.range == range)
        #expect(tools.proposals.count == 1)
    }

    @Test func inlineRewriteDoesNotOfferWholeLineFallback() async throws {
        let text = "Before selected words after"
        let selection = "selected words"
        let snapshot = OwlDocumentSnapshot(text: text, generation: 1, selection: (text as NSString).range(of: selection))
        let context = try #require(OwlChatContext.build(snapshot, scope: .selection, budget: 5000))
        let request = OwlChatRequest(question: "Rewrite Selection", action: .rewrite, context: context, snapshot: snapshot,
                                     useTools: false, prose: true, inlineSelection: selection)
        let outcome = try await OwlChatRunner.run(request, engine: FakeChatEngine(delay: 0)) { _ in }
        #expect(OwlChatRunner.fencedBlock(outcome.answer) != nil)
        #expect(outcome.proposals.isEmpty)
    }

    @Test func rewriteUsesTheExistingProposalPath() async throws {
        let selection = "selected words"
        let text = "Before\nselected words\nAfter"
        let range = (text as NSString).range(of: selection)
        let snapshot = OwlDocumentSnapshot(text: text, generation: 1, selection: range)
        let context = try #require(OwlChatContext.build(snapshot, scope: .selection, budget: 5000))
        let request = OwlChatRequest(question: "Rewrite Selection", action: .rewrite, context: context, snapshot: snapshot,
                                     useTools: true, prose: true, inlineSelection: selection)
        let outcome = try await OwlChatRunner.run(request, engine: FakeChatEngine(delay: 0)) { _ in }
        let proposal = try #require(outcome.proposal)
        #expect(proposal.anchor == .text && proposal.original == selection)
        #expect(proposal.state(text: text as NSString, generation: 1) == .ready(range))
    }

    @Test func configuredServerModelUsesTheEngineScoreKey() {
        let configured = LocalAISettings(enabled: true, backend: .ollama, model: "qwen")
        #expect(OwlChatEngines.configuredScoreKey(settings: configured) == "ollama:qwen")
        var automatic = configured
        automatic.model = nil
        #expect(OwlChatEngines.configuredScoreKey(settings: automatic) == nil)
        automatic.enabled = false
        #expect(OwlChatEngines.configuredScoreKey(settings: automatic) == nil)
    }
}
