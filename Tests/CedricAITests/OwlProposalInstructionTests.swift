import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// What Cedric is told after proposing an edit, and what the edit quick
/// actions ask for: he proposes; nothing is applied until the user
/// presses Apply. Never "you changed", "fixed" or "applied".
@Suite struct OwlProposalInstructionTests {
    static let doc = "Line one.\nLine two.\nLine three.\n"
    static func snap() -> OwlDocumentSnapshot { OwlDocumentSnapshot(text: doc, generation: 1, fileName: "a.txt", language: "plain") }

    static func instructions() -> [String] {
        let s = snap()
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        let result = OwlTools.run(OwlToolCall(name: "propose_edit", arguments: .object([
            "find": .string("Line two."), "replace": .string("Line 2."), "reason": .string("r")])), on: s)
        var out = [result.text]
        for action in [OwlQuickAction.rewrite, .addComments] {
            for tools in [true, false] {
                out.append(OwlPrompts.quickInstruction(action, prose: action == .rewrite, toolsOn: tools, context: ctx))
            }
        }
        return out
    }

    @Test func proposeEditSuccessSaysWhatIsProposedNotChanged() {
        let r = OwlTools.run(OwlToolCall(name: "propose_edit", arguments: .object([
            "find": .string("Line two."), "replace": .string("Line 2."), "reason": .string("r")])), on: Self.snap())
        #expect(r.ok && r.proposal != nil)
        #expect(r.text.hasSuffix("otherwise briefly say what you propose. Nothing is applied until the user presses Apply."))
    }

    @Test func quickActionsEndWithWhatIsProposed() {
        let ctx = OwlChatContext.build(Self.snap(), scope: .wholeDocument, budget: 6000)!
        #expect(OwlPrompts.quickInstruction(.rewrite, prose: true, toolsOn: true, context: ctx)
            .hasSuffix("then say in one sentence what you propose; nothing is applied until the user presses Apply."))
        #expect(OwlPrompts.quickInstruction(.rewrite, prose: true, toolsOn: false, context: ctx)
            .hasSuffix("then one sentence on what you propose; nothing is applied until the user presses Apply."))
    }

    @Test func noInstructionClaimsTheChangeWasMade() {
        for text in Self.instructions() {
            let t = text.lowercased()
            #expect(!t.contains("you changed"), "\(text)")
            #expect(!t.contains("fixed"), "\(text)")
            #expect(!t.contains("you applied") && !t.contains("was applied") && !t.contains("have applied"), "\(text)")
            #expect(t.contains("propose"), "\(text)")
            #expect(text.contains("until the user presses Apply"), "\(text)")
        }
    }
}
