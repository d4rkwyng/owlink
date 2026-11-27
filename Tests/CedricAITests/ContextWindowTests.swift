import Foundation
import Testing
@testable import CedricAI

/// The context window as Ask Cedric's budget: the conversion, and the
/// built-in engine's n_ctx by memory and model size.
@Suite struct ContextWindowMathTests {
    @Test func tokensBecomeUnitsAfterTheReplyReserve() {
        #expect(ContextWindow.budgetUnits(contextTokens: 16_384) == 23_040)
        #expect(ContextWindow.budgetUnits(contextTokens: 8_192) == 10_752)
        #expect(ContextWindow.budgetUnits(contextTokens: 4_096) == 4_608)
        #expect(ContextWindow.budgetUnits(contextTokens: 1_024) == 0)
        #expect(ContextWindow.budgetUnits(contextTokens: 600) == 0, "never negative")
    }

    @Test func serverBudgetIsTheCapUnlessTheWindowIsSmaller() {
        #expect(ContextWindow.serverBudget(contextTokens: nil) == 32_000, "unknown: as before")
        #expect(ContextWindow.serverBudget(contextTokens: 4_096) == 4_608)
        #expect(ContextWindow.serverBudget(contextTokens: 16_384) == 23_040)
        #expect(ContextWindow.serverBudget(contextTokens: 22_357) == 31_999)
        #expect(ContextWindow.serverBudget(contextTokens: 22_358) == 32_000)
        #expect(ContextWindow.serverBudget(contextTokens: 131_072) == 32_000, "never above the cap")
    }

    /// 0.5.3 multiplied the reported window by three before the 32 000
    /// cap: a server reporting a window near Int.max trapped (overflow).
    @Test func anyReportedWindowGivesABudgetWithoutTrapping() {
        for huge in [Int.max, Int.max - 1, Int.max / 2, Int.max / 3 + 1, 1 << 62, 1 << 40, ContextWindow.maximumWindowTokens + 1] {
            #expect(ContextWindow.serverBudget(contextTokens: huge) == 32_000, "\(huge)")
            #expect(ContextWindow.budgetUnits(contextTokens: huge) == ContextWindow.budgetUnits(contextTokens: ContextWindow.maximumWindowTokens))
        }
        #expect(ContextWindow.budgetUnits(contextTokens: ContextWindow.maximumWindowTokens) == (ContextWindow.maximumWindowTokens - 1_024) * 3 / 2)
        for low in [Int.min, Int.min + 1, -1, 0] {
            #expect(ContextWindow.budgetUnits(contextTokens: low) == 0)
            #expect(ContextWindow.serverBudget(contextTokens: low) == 0)
        }
    }
}

@Suite struct BuiltInContextTests {
    static let gib: UInt64 = 1 << 30
    func model(_ id: String) throws -> BuiltInModel {
        try #require(ModelCatalog.bundled()?.model(id: id))
    }

    @Test func eightGigabyteMacsGetWhatFitsInHalfTheirMemory() throws {
        let ram = 8 * Self.gib
        // 2.50 GB of weights + 147 456 B/token: 16k needs 5.45 GB > 4.29 GB, 8k needs 4.24 GB.
        #expect(try model("qwen3-4b-instruct-2507-q4_k_m").contextTokens(physicalMemory: ram) == 8_192)
        #expect(try model("qwen3-4b-q4_k_m").contextTokens(physicalMemory: ram) == 8_192)
        // Qwen2.5's 2 KV heads: a small cache.
        #expect(try model("qwen2.5-coder-3b-instruct-q4_k_m").contextTokens(physicalMemory: ram) == 16_384)
        #expect(try model("qwen2.5-coder-1.5b-instruct-q4_k_m").contextTokens(physicalMemory: ram) == 16_384)
        // 4.68 GB of weights alone is more than half of 8 GB: the floor.
        #expect(try model("qwen2.5-coder-7b-instruct-q4_k_m").contextTokens(physicalMemory: ram) == 4_096)
    }

    @Test func sixteenGigabytesAndUpGetTheLargestWindowForEveryModel() throws {
        let catalog = try #require(ModelCatalog.bundled())
        for ram in [16 * Self.gib, 24 * Self.gib, 64 * Self.gib] {
            for m in catalog.models {
                #expect(m.contextTokens(physicalMemory: ram) == 16_384, "\(m.id) at \(ram >> 30) GB")
            }
        }
    }

    @Test func pureFunctionSteps() {
        let gb: Int64 = 1_000_000_000
        // 1 GB weights, 100 KB/token: 16k = 1 + 1.68 + 0.54 GB = 3.21 GB.
        #expect(ContextWindow.builtInContextTokens(modelBytes: gb, kvBytesPerToken: 100_000, physicalMemory: 7 * Self.gib) == 16_384)
        #expect(ContextWindow.builtInContextTokens(modelBytes: gb, kvBytesPerToken: 100_000, physicalMemory: 5 * Self.gib) == 8_192)
        #expect(ContextWindow.builtInContextTokens(modelBytes: gb, kvBytesPerToken: 100_000, physicalMemory: 3 * Self.gib) == 4_096)
        #expect(ContextWindow.builtInContextTokens(modelBytes: 10 * gb, kvBytesPerToken: 100_000, physicalMemory: 4 * Self.gib) == 4_096,
                "the floor even when nothing fits")
        #expect(ContextWindow.builtInContextTokens(modelBytes: 0, kvBytesPerToken: 0, physicalMemory: 0) == 4_096)
    }

    @Test func moreMemoryNeverShrinksTheWindow() throws {
        let catalog = try #require(ModelCatalog.bundled())
        for m in catalog.models {
            var last = 0
            for gb in stride(from: 2, through: 96, by: 2) {
                let n = m.contextTokens(physicalMemory: UInt64(gb) * Self.gib)
                #expect(ContextWindow.builtInSteps.contains(n))
                #expect(n >= last, "\(m.id): \(gb) GB gave \(n) after \(last)")
                last = n
            }
        }
    }

    @Test func everyCatalogModelHasItsKVCacheSizeAndTheGuessIsNotSmaller() throws {
        let catalog = try #require(ModelCatalog.bundled())
        for m in catalog.models {
            let kv = try #require(m.kvBytesPerToken, "\(m.id) has no kvBytesPerToken")
            var guessed = m
            guessed.kvBytesPerToken = nil
            #expect(guessed.kvCacheBytesPerToken >= kv, "\(m.id): the guess must not undercount")
        }
        var bad = try #require(catalog.models.first)
        bad.kvBytesPerToken = 0
        #expect(throws: ModelCatalogError.self) { try ModelCatalog(models: [bad]).validate() }
    }

    /// The engine's budget and the runtime's n_ctx come from the same
    /// function: the prompt the budget allows (at 1.5 units per token)
    /// plus the largest answer Ask Cedric asks for fits in n_ctx.
    @Test func engineBudgetFollowsTheRuntimesWindow() throws {
        let catalog = try #require(ModelCatalog.bundled())
        for m in catalog.models {
            let engine = BuiltInChatEngine(model: m, path: URL(fileURLWithPath: "/nonexistent/\(m.fileName)"))
            let n = m.contextTokens()
            #expect(engine.contextBudget == ContextWindow.budgetUnits(contextTokens: n))
            #expect(engine.contextBudget * 2 / 3 + 700 <= n)
        }
    }
}
