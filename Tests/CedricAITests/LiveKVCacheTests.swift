import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// KV-cache reuse across tool rounds, on a real model: a fixed 3-round
/// tool conversation (the prompts Ask Cedric sends, with real tool
/// results) run twice, cache cleared on every request (0.2) and reused
/// (0.3), greedy. Prints tokens processed and prefill time per round and
/// checks both runs write the same text. Then one real Ask Cedric
/// question through the runner, per round. Skipped unless
/// CEDRIC_KV_LIVE=1; CEDRIC_BUILTIN_MODEL=<catalog id> picks the model.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["CEDRIC_KV_LIVE"] == "1"), .serialized)
struct LiveKVCacheTests {
    static func rounds() -> [[OwlChatMessage]] {
        let d = OwlToolEval.docs["md"]!
        let probe = OwlDocumentSnapshot(text: d.text, generation: 1)
        let snap = OwlDocumentSnapshot(text: d.text, generation: 1, visible: probe.range(lines: 1, 12)!, fileName: d.file, language: d.language)
        let ctx = OwlChatContext.build(snap, scope: .visible, budget: 6000)!
        var m = OwlPrompts.chatMessages(question: "Find the harvest section, then tell me the total kg picked in weeks 9 and 10 together.",
                                        context: ctx, language: "Markdown", fileName: d.file, history: [], toolsOn: true,
                                        model: "builtIn:qwen3")
        var out = [m]
        for call in [OwlToolCall(id: "c1", name: "search_document", arguments: .object(["query": .string("Week 9")])),
                     OwlToolCall(id: "c2", name: "get_lines", arguments: .object(["start": .number(33), "end": .number(34)]))] {
            m.append(.toolCalls([call]))
            m.append(.toolResult(callID: call.id, name: call.name, content: OwlTools.run(call, on: snap).text))
            out.append(m)
        }
        return out
    }

    @Test func threeRoundsReuseThePrefixAndWriteTheSame() async throws {
        let env = ProcessInfo.processInfo.environment
        let catalog = try #require(ModelCatalog.bundled())
        let model = try #require(env["CEDRIC_BUILTIN_MODEL"].flatMap(catalog.model(id:)) ?? catalog.defaultModel)
        let store = ModelStore()
        try #require(store.isInstalled(model), "\(model.id) is not downloaded")
        let host = BuiltInModelHost(runtime: LlamaRuntime())
        let path = store.fileURL(for: model)
        let llama = try #require(try await BuiltInLoad.userAsked { try await host.model(at: path) } as? LlamaModel)
        let specs = OwlTools.specs(OwlToolName.allCases)
        let grammar = OwlToolGrammar.envelope(specs)
        #expect(llama.grammarCompiles(grammar), "llama.cpp rejects the typed grammar")

        var texts: [Bool: [String]] = [:]
        for reuse in [false, true] {
            LlamaModel.reuseKVCache = reuse
            llama.invalidateCache()
            var processed = 0, seconds = 0.0
            for (i, messages) in Self.rounds().enumerated() {
                let chat = BuiltInChatEngine.render(messages, tools: specs)
                let r = try await llama.generate(GenerationRequest(messages: chat, maxTokens: 120, grammar: grammar))
                let new = r.promptTokens - r.reusedTokens
                processed += new
                seconds += r.promptSeconds
                print(String(format: "kv-live: %@ round %d prompt=%d reused=%d processed=%d prefill=%.0f ms generate=%.0f ms (%d tokens) → %@",
                             reuse ? "reuse" : "clear", i + 1, r.promptTokens, r.reusedTokens, new, r.promptSeconds * 1000,
                             r.generateSeconds * 1000, r.completionTokens, String(r.text.prefix(90))))
                texts[reuse, default: []].append(r.text)
                if !reuse { #expect(r.reusedTokens == 0) }
            }
            print(String(format: "kv-live: %@ total processed=%d prefill=%.0f ms", reuse ? "reuse" : "clear", processed, seconds * 1000))
        }
        #expect(texts[false] == texts[true], "greedy output changed with the cache reused")
        print("kv-live: identical outputs: \(texts[false] == texts[true])")
        LlamaModel.reuseKVCache = true

        // A real question through the runner, rounds as the model picks them.
        let engine = BuiltInChatEngine(model: model, path: path, host: host)
        for reuse in [false, true] {
            LlamaModel.reuseKVCache = reuse
            llama.invalidateCache()
            let c = OwlToolEval.scenarios.first { $0.question.hasPrefix("Find the harvest section") }!
            let t0 = Date()
            let r = await OwlToolEval.run(c, engine: engine)
            print(String(format: "kv-live: runner %@ %.2f s pass=%@ → %@", reuse ? "reuse" : "clear", Date().timeIntervalSince(t0),
                         "\(r.pass)", String(r.got.prefix(120))))
        }
        LlamaModel.reuseKVCache = true
        await host.unload()
    }

    /// A hybrid model (Gated DeltaNet + attention, e.g. Qwen3.5): cutting
    /// the cache back is refused, so each request falls back to a full
    /// clear, and the output is the same as with reuse off.
    /// CEDRIC_KV_HYBRID=<path to a GGUF> (not a catalog model; loaded
    /// without the catalog check, tests only).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CEDRIC_KV_HYBRID"] != nil))
    func hybridModelFallsBackToAFullClear() async throws {
        let path = ProcessInfo.processInfo.environment["CEDRIC_KV_HYBRID"]!
        let llama = try LlamaRuntime.loadForTesting(path: path)
        defer { llama.unload() }
        let specs = OwlTools.specs(OwlToolName.allCases)
        let grammar = OwlToolGrammar.envelope(specs)
        var texts: [Bool: [String]] = [:]
        for reuse in [false, true] {
            LlamaModel.reuseKVCache = reuse
            llama.invalidateCache()
            let before = llama.cacheFallbacks
            for (i, messages) in Self.rounds().enumerated() {
                let r = try await llama.generate(GenerationRequest(messages: BuiltInChatEngine.render(messages, tools: specs),
                                                                  maxTokens: 60, grammar: grammar))
                print(String(format: "kv-hybrid: %@ round %d prompt=%d reused=%d prefill=%.0f ms → %@", reuse ? "reuse" : "clear",
                             i + 1, r.promptTokens, r.reusedTokens, r.promptSeconds * 1000, String(r.text.prefix(80))))
                texts[reuse, default: []].append(r.text)
            }
            print("kv-hybrid: \(reuse ? "reuse" : "clear") fallbacks=\(llama.cacheFallbacks - before)")
            if reuse { #expect(llama.cacheFallbacks > before, "the hybrid cache never refused a partial removal") }
        }
        LlamaModel.reuseKVCache = true
        #expect(texts[false] == texts[true])
        print("kv-hybrid: identical outputs: \(texts[false] == texts[true])")
    }
}
