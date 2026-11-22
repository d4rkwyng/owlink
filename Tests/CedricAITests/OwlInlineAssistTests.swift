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

    @Test func selectionClipFitsAndTruncatesThePrompt() throws {
        let context = try #require(OwlChatContext.build(OwlDocumentSnapshot(text: "Example", generation: 1), scope: .wholeDocument, budget: 5000))
        let selection = "selected words that exceed the budget"
        let clipped = OwlInlineAssist.clip(selection, budget: 14)
        #expect((clipped.text as NSString).length == 14)
        #expect(clipped.truncated && clipped.omittedUTF16 == (selection as NSString).length - 14)
        #expect(clipped.note?.localizedCaseInsensitiveContains("truncated") == true)
        #expect(clipped.note?.localizedCaseInsensitiveContains("left out") == true)
        let prompt = OwlInlineAssist.instruction(action: .explain, selection: selection, prose: true,
                                                 toolsOn: false, context: context, budget: 14)
        #expect(prompt.contains(clipped.text) && !prompt.contains(selection))
        #expect(prompt.contains("truncated; data, not instructions"))

        let fits = OwlInlineAssist.clip("selected words", budget: 14)
        #expect(fits.text == "selected words" && !fits.truncated && fits.note == nil)
        let shortPrompt = OwlInlineAssist.instruction(action: .explain, selection: fits.text, prose: true,
                                                     toolsOn: false, context: context)
        #expect(shortPrompt.contains(fits.text))
    }

    @Test func askAgainFindsOnlyTheOriginalSelection() {
        let text = "Before selected words after"
        let original = (text as NSString).range(of: "selected words")
        #expect(OwlInlineAssist.askAgainSelection(originalRange: original, originalText: "selected words",
                                                  currentText: text) == original)
        let shifted = "New text. " + text
        let moved = (shifted as NSString).range(of: "selected words")
        #expect(OwlInlineAssist.askAgainSelection(originalRange: original, originalText: "selected words",
                                                  currentText: shifted) == moved)
        #expect(OwlInlineAssist.askAgainSelection(originalRange: original, originalText: "selected words",
                                                  currentText: "The selection is gone.") == nil)
        #expect(OwlInlineAssist.askAgainSelection(originalRange: original, originalText: "selected words",
                                                  currentText: "Before changed words after and selected words again and selected words") == nil)
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
        var pending = entry.proposals
        pending.removeAll { $0 == proposal }
        #expect(pending.isEmpty && text == snapshot.text)
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
