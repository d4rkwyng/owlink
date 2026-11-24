import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Edit validation in Ask Cedric (0.5.3): JavaScriptCore's syntax check
/// (never running the script), the propose_edit handler's one retry, and
/// the quick action's ``` block marked directly.
@Suite struct OwlEditValidationAITests {
    static let appJS = """
    const express = require('express');
    const app = express();

    function debounce(fn, ms) {
      let t;
      return (...args) => {
        clearTimeout(t);
        t = setTimeout(() => fn(...args), ms);
      };
    }

    app.get('/user/:id', async (req, res) => {
      const user = await db.find(req.params.id);
      res.send('<h1>' + user.name + '</h1>');   // FIXME: XSS
    });

    for (var i = 0; i < 3; i++) {
      setTimeout(() => console.log(i), 10);
    }

    app.listen(3000);

    """

    static let validJSON = """
    {
      "name": "demo",
      "items": [1, 2, 3],
      "ok": true
    }

    """

    static func edit(_ find: String, _ replace: String) -> OwlToolCall {
        OwlToolCall(name: "propose_edit", arguments: .object(["find": .string(find), "replace": .string(replace), "reason": .string("r")]))
    }

    // MARK: JavaScriptCore

    @Test func jscChecksSyntaxOnly() {
        let jsc = JSCSyntaxChecker()
        #expect(jsc.syntaxError(in: Self.appJS) == nil)
        let bad = Self.appJS.replacingOccurrences(of: "setTimeout(() => console.log(i), 10);", with: "setTimeout(() => console.log(i), 10;")
        let e = jsc.syntaxError(in: bad)
        #expect(e != nil)
        #expect(e?.line == 18)
        // A script that would have an effect if it ran: it only parses.
        #expect(jsc.syntaxError(in: "while (true) {}\nthrow new Error('ran')") == nil)
    }

    @Test func appJSEditsThroughJSC() throws {
        let s = OwlDocumentSnapshot(text: Self.appJS, generation: 1, fileName: "app.js", language: "javascript")
        func check(_ find: String, _ replace: String) throws -> OwlEditCheck {
            let p = try OwlEditProposal.anchored(find: find, replace: replace, in: s).get()
            return OwlEditValidation.validate(p, in: s, script: JSCSyntaxChecker())
        }
        #expect(try check("for (var i = 0;", "for (let i = 0;") == .clean)
        let unclosed = try check("setTimeout(() => console.log(i), 10);", "setTimeout(() => console.log(i), 10;")
        #expect(unclosed.hardIssue?.check == .script)
        #expect(unclosed.issues.contains { $0.check == .brackets })
        let selfInit = try check("  setTimeout(() => console.log(i), 10);\n}", "  const i = i;\n  setTimeout(() => console.log(i), 10);\n}")
        #expect(selfInit.hardIssue?.check == .selfInitialization)
    }

    @Test func moduleSyntaxRejectedBeforeAndAfterIsNotTheEditsFault() throws {
        let doc = "import x from 'y';\n\nexport const a = x(1);\n"
        #expect(JSCSyntaxChecker().syntaxError(in: doc) != nil)
        let s = OwlDocumentSnapshot(text: doc, generation: 1, fileName: "m.js", language: "javascript")
        let p = try OwlEditProposal.anchored(find: "x(1)", replace: "x(2)", in: s).get()
        #expect(OwlEditValidation.validate(p, in: s, script: JSCSyntaxChecker()) == .clean)
    }

    @Test func addingExportToAValidFileIsAWarningThroughJSC() throws {
        for name in ["m.mjs", "m.js"] {
            let s = OwlDocumentSnapshot(text: "const a = 1;\n", generation: 1, fileName: name, language: "javascript")
            let p = try OwlEditProposal.anchored(find: "const a", replace: "export const a", in: s).get()
            let c = OwlEditValidation.validate(p, in: s, script: JSCSyntaxChecker())
            #expect(!c.failsValidation, "\(name)")
            #expect(c.warnings.first?.message.hasPrefix("May not parse: ") == true, "\(name)")
        }
    }

    @Test func aRegexAfterAConditionPassesThroughJSC() {
        let after = "if (ok) /\\(/.test(s);\n"
        #expect(JSCSyntaxChecker().syntaxError(in: after) == nil)
        let c = OwlEditValidation.validate(language: "javascript", fileName: "a.js", before: "", after: after,
                                           original: "", replacement: after, script: JSCSyntaxChecker())
        #expect(c == .clean)
    }

    @Test func jscSourceNeverRunsScripts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/CedricAI/JSCSyntaxChecker.swift"), encoding: .utf8)
        #expect(source.contains("JSCheckScriptSyntax"))
        for banned in ["evaluateScript", "JSEvaluateScript", "new Function", "JSObjectCallAsFunction", "JSContext("] {
            #expect(!source.contains(banned), "\(banned)")
        }
    }

    // MARK: The propose_edit retry

    @Test func firstInvalidEditIsRefusedThenMarked() {
        let s = OwlDocumentSnapshot(text: Self.validJSON, generation: 1, fileName: "a.json", language: "json")
        let box = OwlToolbox(snapshot: s, allowed: [.proposeEdit])
        let first = box.run(Self.edit("[1, 2, 3]", "[1, 2, 3,]"))
        #expect(!first.ok && first.proposal == nil)
        #expect(first.text.hasPrefix("error: the change doesn't parse: "))
        #expect(first.text.contains("(line 3)") && first.text.hasSuffix("fix it and call propose_edit again"))
        #expect(box.proposals.isEmpty)
        // Failing again (any edit): proposed, marked, Apply off.
        let second = box.run(Self.edit("\"ok\": true", "\"ok\": true,"))
        #expect(second.ok)
        #expect(second.text.hasPrefix("proposed, but it still fails the check (") && second.text.contains("can't apply it"))
        let p = try? #require(box.proposals.first)
        #expect(box.proposals.count == 1)
        #expect(p?.check.failsValidation == true)
        #expect(p?.check.failureText?.hasPrefix("Doesn’t parse: ") == true)
        #expect(p?.canApply(text: Self.validJSON as NSString, generation: 1) == false)
        if case .failsValidation? = p?.state(text: Self.validJSON as NSString, generation: 1) {} else { Issue.record("Apply should be off") }
    }

    @Test func invalidThenValidIsANormalProposal() {
        let s = OwlDocumentSnapshot(text: Self.validJSON, generation: 1, fileName: "a.json", language: "json")
        let box = OwlToolbox(snapshot: s, allowed: [.proposeEdit])
        #expect(!box.run(Self.edit("[1, 2, 3]", "[1, 2, 3,]")).ok)
        let fixed = box.run(Self.edit("[1, 2, 3]", "[1, 2, 3, 4]"))
        #expect(fixed.ok && fixed.text.hasPrefix("proposed: "))
        #expect(box.proposals.count == 1 && box.proposals[0].check == .clean)
        #expect(box.proposals[0].canApply(text: Self.validJSON as NSString, generation: 1))
        // The five-edit cap is unchanged.
        #expect(OwlTools.maxProposals == 5)
    }

    /// Proposes a broken edit, then (told it doesn't parse) a fixed one.
    struct Retrying: OwlChatEngine {
        let fix: Bool
        var title: String { "retrying" }
        var scoreKey: String { "retrying" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            let results = messages.compactMap { m -> String? in if case .toolResult(_, _, let c) = m { return c }; return nil }
            if !tools.isEmpty, results.count < 2 {
                if results.isEmpty { return .toolCalls([OwlEditValidationAITests.edit("[1, 2, 3]", "[1, 2, 3,]")]) }
                #expect(results[0].contains("doesn't parse"))
                return .toolCalls([OwlEditValidationAITests.edit("[1, 2, 3]", fix ? "[1, 2, 3, 4]" : "[1, 2, 3,, 4]")])
            }
            onText("I propose adding 4.")
            return .answer("I propose adding 4.")
        }
    }

    @Test func runnerRetriesOnceThroughTheToolLoop() async throws {
        let s = OwlDocumentSnapshot(text: Self.validJSON, generation: 1, fileName: "a.json", language: "json")
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        let req = OwlChatRequest(question: "Change the items to add 4.", context: ctx, snapshot: s, useTools: true, prose: false)
        #expect(req.tools.contains(.proposeEdit))
        let fixed = try await OwlChatRunner.run(req, engine: Retrying(fix: true)) { _ in }
        #expect(fixed.proposals.count == 1 && fixed.proposals[0].check == .clean)
        let broken = try await OwlChatRunner.run(req, engine: Retrying(fix: false)) { _ in }
        #expect(broken.proposals.count == 1 && broken.proposals[0].check.failsValidation)
    }

    /// Looks (get_lines) until the last tool round, then proposes a broken edit there.
    struct BreaksInTheLastRound: OwlChatEngine {
        var title: String { "last-round" }
        var scoreKey: String { "last-round" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            let results = messages.compactMap { m -> String? in if case .toolResult(_, _, let c) = m { return c }; return nil }
            if !tools.isEmpty {
                if results.count < OwlTools.maxRounds - 1 {
                    return .toolCalls([OwlToolCall(name: "get_lines", arguments: .object(["start": .number(1), "end": .number(2)]))])
                }
                return .toolCalls([OwlEditValidationAITests.edit("[1, 2, 3]", "[1, 2, 3,]")])
            }
            onText("I propose adding a comma.")
            return .answer("I propose adding a comma.")
        }
    }

    @Test func aFailingEditInTheLastToolRoundIsMarkedNotRefused() async throws {
        let s = OwlDocumentSnapshot(text: Self.validJSON, generation: 1, fileName: "a.json", language: "json")
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        let req = OwlChatRequest(question: "Change the items.", context: ctx, snapshot: s, useTools: true, prose: false)
        let results = TextBuffer()
        let out = try await OwlChatRunner.run(req, engine: Recording(inner: BreaksInTheLastRound(), seen: results)) { _ in }
        #expect(out.rounds == OwlTools.maxRounds)
        // No "call propose_edit again" with no tool round left: the card is marked, Apply off.
        #expect(!results.value.contains("call propose_edit again"))
        #expect(results.value.contains("proposed, but it still fails the check"))
        let p = try #require(out.proposals.first)
        #expect(out.proposals.count == 1 && p.check.failsValidation)
        #expect(!p.canApply(text: Self.validJSON as NSString, generation: 1))
    }

    /// Two broken edits in one batch, then (told) both fixed, or both still broken.
    struct TwoInABatch: OwlChatEngine {
        let fix: Bool
        var title: String { "two" }
        var scoreKey: String { "two" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            let results = messages.compactMap { m -> String? in if case .toolResult(_, _, let c) = m { return c }; return nil }
            if !tools.isEmpty, results.count < 4 {
                if results.isEmpty {
                    return .toolCalls([OwlEditValidationAITests.edit("[1, 2, 3]", "[1, 2, 3,]"),
                                       OwlEditValidationAITests.edit("\"ok\": true", "\"ok\": true,")])
                }
                // Both were refused before either became a card.
                #expect(results.count == 2 && results.allSatisfy { $0.hasSuffix("fix it and call propose_edit again") })
                return .toolCalls([OwlEditValidationAITests.edit("[1, 2, 3]", fix ? "[1, 2, 3, 4]" : "[1, 2, 3,, 4]"),
                                   OwlEditValidationAITests.edit("\"ok\": true", fix ? "\"ok\": false" : "\"ok\": tru")])
            }
            onText("I propose two changes.")
            return .answer("I propose two changes.")
        }
    }

    @Test func everyFailingEditInTheRefusedBatchWaitsForTheRetryRound() async throws {
        let s = OwlDocumentSnapshot(text: Self.validJSON, generation: 1, fileName: "a.json", language: "json")
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        let req = OwlChatRequest(question: "Change the items and ok.", context: ctx, snapshot: s, useTools: true, prose: false)
        let events = EventLog()
        let fixed = try await OwlChatRunner.run(req, engine: TwoInABatch(fix: true)) { e in events.add(e) }
        #expect(fixed.proposals.count == 2 && fixed.proposals.allSatisfy { $0.check == .clean })
        // No failing card was shown along the way.
        #expect(events.proposals.allSatisfy { !$0.check.failsValidation } && events.proposals.count == 2)
        // Still broken in the retry round: both marked, Apply off.
        let broken = try await OwlChatRunner.run(req, engine: TwoInABatch(fix: false)) { _ in }
        #expect(broken.proposals.count == 2 && broken.proposals.allSatisfy { $0.check.failsValidation })
    }

    /// Passes turns through, keeping every tool result the model saw.
    struct Recording: OwlChatEngine {
        let inner: any OwlChatEngine
        let seen: TextBuffer
        var title: String { inner.title }
        var scoreKey: String { inner.scoreKey }
        var contextBudget: Int { inner.contextBudget }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            // The answer turn (no tools) has every result in its messages.
            if tools.isEmpty {
                for m in messages { if case .toolResult(_, _, let c) = m { seen.append(c + "\n") } }
            }
            return try await inner.turn(messages, tools: tools, toolbox: toolbox, maxTokens: maxTokens, onText: onText)
        }
    }

    final class EventLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _proposals: [OwlEditProposal] = []
        func add(_ e: OwlChatEvent) { if case .proposal(let p) = e { lock.withLock { _proposals.append(p) } } }
        var proposals: [OwlEditProposal] { lock.withLock { _proposals } }
    }

    /// A quick action without tools: the ``` block.
    struct Block: OwlChatEngine {
        let body: String
        var title: String { "block" }
        var scoreKey: String { "block" }
        var contextBudget: Int { 6000 }
        func turn(_ messages: [OwlChatMessage], tools: [OwlToolSpec], toolbox: OwlToolbox?, maxTokens: Int,
                  onText: @escaping @Sendable (String) -> Void) async throws -> OwlTurn {
            .answer("```\n" + body + "\n```\nI propose this.")
        }
    }

    @Test func quickActionBlockIsValidatedAndMarked() async throws {
        let s = OwlDocumentSnapshot(text: Self.validJSON, generation: 1, fileName: "a.json", language: "json")
        let ctx = OwlChatContext.build(s, scope: .wholeDocument, budget: 6000)!
        let req = OwlChatRequest(question: "Simplify", action: .rewrite, context: ctx, snapshot: s, useTools: false, prose: false)
        let bad = try await OwlChatRunner.run(req, engine: Block(body: "{\n  \"name\": \"demo\",\n  \"items\": [1, 2, 3,],\n  \"ok\": true\n}")) { _ in }
        let p = try #require(bad.proposals.first)
        #expect(p.anchor == .lines && p.check.failsValidation)
        #expect(!p.canApply(text: Self.validJSON as NSString, generation: 1))
        let good = try await OwlChatRunner.run(req, engine: Block(body: "{\n  \"name\": \"demo\",\n  \"items\": [1, 2],\n  \"ok\": true\n}")) { _ in }
        #expect(good.proposals.first?.check == .clean)
        #expect(good.proposals.first?.canApply(text: Self.validJSON as NSString, generation: 1) == true)
    }
}
