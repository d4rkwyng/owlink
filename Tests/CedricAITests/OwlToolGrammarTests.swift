import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// The typed tool-call grammar (`OwlToolGrammar`): generated from each
/// tool's JSON schema, checked here with a small GBNF interpreter
/// (`GBNFMatcher`, the same language llama.cpp reads), and the parsing of
/// what it lets through. The live eval checks llama.cpp itself compiles it.
@Suite struct OwlToolGrammarTests {
    static let all = OwlTools.specs(OwlToolName.allCases)

    static func matcher(_ tools: [OwlToolSpec] = all) throws -> GBNFMatcher {
        try GBNFMatcher(OwlToolGrammar.envelope(tools))
    }

    @Test func theGrammarParsesAndEveryRuleResolves() throws {
        let g = OwlToolGrammar.envelope(Self.all)
        _ = try GBNFMatcher(g)
        #expect(g.hasPrefix("root ::= answer | call"))
        for t in OwlToolName.allCases { #expect(g.contains("tool-\(t.rawValue.replacingOccurrences(of: "_", with: "-")) ::=")) }
        // Only the offered tools.
        let two = OwlToolGrammar.envelope(OwlTools.specs([.getLines, .proposeEdit]))
        #expect(!two.contains("search_document"))
        #expect(two.contains("get_lines") && two.contains("propose_edit"))
        // No tools: an answer only.
        let none = try GBNFMatcher(OwlToolGrammar.envelope([]))
        #expect(none.matches(#"{"answer":"hi"}"#))
        #expect(!none.matches(#"{"tool":"get_outline","args":{}}"#))
    }

    @Test func acceptsWellTypedCalls() throws {
        let m = try Self.matcher()
        for ok in [
            #"{"answer":"Line 3 says \"hi\"\nok"}"#,
            #"{ "answer": "x" }"#,
            #"{"tool":"get_lines","args":{"start":40,"end":44}}"#,
            #"{"tool": "get_lines", "args": {"start": 40, "end": 44}}"#,
            #"{"tool":"search_document","args":{"query":"parseConfig"}}"#,
            #"{"tool":"search_document","args":{"query":"a.b","regex":true}}"#,
            #"{"tool":"get_outline","args":{}}"#,
            #"{"tool":"get_selection","args":{ }}"#,
            #"{"tool":"document_stats","args":{}}"#,
            #"{"tool":"describe_image","args":{}}"#,
            #"{"tool":"propose_edit","args":{"find":"struct Config {","replace":"struct AppConfig {","reason":"rename"}}"#,
            #"{"tool":"propose_edit","args":{"find":"a","replace":"a\nb","reason":""}}"#,
        ] { #expect(m.matches(ok), "\(ok)") }
    }

    @Test func rejectsWhatTheUntypedGrammarLetThrough() throws {
        let m = try Self.matcher()
        for bad in [
            #"{"tool":"get_lines","args":{"start":"40","end":"44"}}"#,      // quoted integers
            #"{"tool":"get_lines","args":{"start":40}}"#,                    // end is required
            #"{"tool":"get_lines","args":{"strat":40,"end":44}}"#,           // misspelt key
            #"{"tool":"get_lines","args":{"start":40,"end":44,"x":1}}"#,     // unknown key
            #"{"tool":"get_lines","args":{"end":44,"start":40}}"#,           // fixed order
            #"{"tool":"get_lines","args":{"start":4.5,"end":44}}"#,          // not an integer
            #"{"tool":"search_document","args":{"query":7}}"#,               // not a string
            #"{"tool":"search_document","args":{"query":"a","regex":"yes"}}"#,
            #"{"tool":"search_document","args":{"regex":true}}"#,            // query is required
            #"{"tool":"describe_image","args":{"path":"x.svg"}}"#,           // takes no arguments
            #"{"tool":"propose_edit","args":{"find":"a","replace":"b"}}"#,  // reason is required
            #"{"tool":"propose_edit","args":{"start":3,"end":3,"new_text":"x"}}"#,  // no line ranges (0.4.1)
            #"{"tool":"get_outline","args":{"depth":2}}"#,                   // takes nothing
            #"{"tool":"delete_file","args":{}}"#,                             // no such tool
            #"{"answer":"x","tool":"get_outline"}"#,
            #"I think line 3 is fine."#,
        ] { #expect(!m.matches(bad), "\(bad)") }
    }

    @Test func searchQueryIsCappedLikeTheTool() throws {
        let m = try Self.matcher(OwlTools.specs([.searchDocument]))
        let ok = String(repeating: "a", count: OwlTools.maxPatternLength)
        #expect(m.matches(#"{"tool":"search_document","args":{"query":""# + ok + #""}}"#))
        #expect(!m.matches(#"{"tool":"search_document","args":{"query":""# + ok + #"a"}}"#))
    }

    @Test func schemaFeaturesBeyondTodaysTools() throws {
        // Enums, numbers, all-optional objects.
        let spec = OwlJSON.object([
            "type": .string("object"),
            "properties": .object([
                "mode": .object(["type": .string("string"), "enum": .array([.string("fast"), .string("slow")])]),
                "scale": .object(["type": .string("number")]),
                "verbose": .object(["type": .string("boolean")]),
            ]),
        ])
        let m = try GBNFMatcher("root ::= " + OwlToolGrammar.object(spec) + "\n" + OwlToolGrammar.shared.joined(separator: "\n"))
        for ok in ["{}", #"{"mode":"fast"}"#, #"{"scale":1.5}"#, #"{"mode":"slow","scale":-2,"verbose":false}"#, #"{"scale":2,"verbose":true}"#] {
            #expect(m.matches(ok), "\(ok)")
        }
        for bad in [#"{"mode":"medium"}"#, #"{"verbose":"no"}"#, #"{"scale":"1"}"#, #"{"verbose":true,"mode":"fast"}"#] {
            #expect(!m.matches(bad), "\(bad)")
        }
    }

    @Test func constrainedOutputParsesToTypedCalls() throws {
        let m = try Self.matcher()
        let out = #"{"tool": "get_lines", "args": {"start": 40, "end": 44}}"#
        #expect(m.matches(out))
        guard case .toolCalls(let calls)? = EnvelopeStreamParser.parse(out), let c = calls.first else {
            Issue.record("no call"); return
        }
        #expect(c.name == "get_lines")
        #expect(c.arguments["start"] == .number(40) && c.arguments["end"] == .number(44))
        let snap = OwlDocumentSnapshot(text: (1...50).map { "line \($0)" }.joined(separator: "\n"), generation: 1)
        #expect(OwlTools.run(c, on: snap).ok)
        let edit = #"{"tool":"propose_edit","args":{"find":"line 2\n","replace":"new \"two\"\n","reason":"r"}}"#
        #expect(m.matches(edit))
        guard case .toolCalls(let e)? = EnvelopeStreamParser.parse(edit) else { Issue.record("no edit"); return }
        #expect(e[0].arguments["replace"] == .string("new \"two\"\n"))
        #expect(OwlTools.run(e[0], on: snap).proposal?.firstLine == 2)
        let answer = #"{"answer":"Line 3 says \"hi\""}"#
        #expect(m.matches(answer))
        #expect(EnvelopeStreamParser.parse(answer) == .answer("Line 3 says \"hi\""))
    }

    @Test func theEngineSendsTheTypedGrammar() async throws {
        let runtime = GrammarSpy()
        let host = BuiltInModelHost(runtime: runtime)
        let model = try #require(ModelCatalog.bundled()?.defaultModel)
        let engine = BuiltInChatEngine(model: model, path: URL(fileURLWithPath: "/x/\(model.fileName)"), host: host)
        // Ask Cedric: the user asked (BuiltInLoadIntent), so it may load.
        _ = try await BuiltInLoad.userAsked {
            try await engine.turn([.system("s"), .user("q")], tools: OwlTools.specs([.getLines]), toolbox: nil, maxTokens: 10) { _ in }
        }
        let g = try #require(runtime.grammars.value.first ?? nil)
        #expect(g == OwlToolGrammar.envelope(OwlTools.specs([.getLines])))
        #expect(g.contains(#""\"start\"" ws ":" ws integer"#))
    }

    final class GrammarSpy: BuiltInRuntime, @unchecked Sendable {
        let grammars = Box<[String?]>([])
        func load(modelAt url: URL) async throws -> any LoadedModel { Model(spy: self) }
        final class Model: LoadedModel, @unchecked Sendable {
            let spy: GrammarSpy
            init(spy: GrammarSpy) { self.spy = spy }
            func generate(_ request: GenerationRequest) async throws -> GenerationResult {
                spy.grammars.mutate { $0.append(request.grammar) }
                return GenerationResult(text: #"{"answer":"ok"}"#)
            }
            func unload() {}
        }
    }
}
