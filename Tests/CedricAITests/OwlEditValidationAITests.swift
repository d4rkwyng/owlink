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
