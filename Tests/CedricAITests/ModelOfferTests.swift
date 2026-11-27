import Foundation
import Testing
@testable import CedricAI
import CedricCore

/// Which built-in models each device is offered (the iOS port).
@Suite struct ModelOfferTests {
    let catalog = ModelCatalog.bundled()!

    @Test func macGetsEveryModel() {
        #expect(catalog.offered(on: .mac) == catalog.models)
    }

    @Test func iPhoneGetsOnlySmallModels() {
        let list = catalog.offered(on: .iPhone)
        #expect(!list.isEmpty)
        #expect(list.allSatisfy { $0.parametersB <= 2.0 && $0.sizeBytes < 1_500_000_000 })
        #expect(catalog.offered(on: .iPad(largeMemory: false)) == list)
        #expect(catalog.defaultModel(on: .iPhone).map { list.contains($0) } == true)
    }

    @Test func mSeriesIPadAlsoGetsTheFourB() {
        let list = catalog.offered(on: .iPad(largeMemory: true))
        #expect(list.contains { $0.id == "qwen3-4b-instruct-2507-q4_k_m" })
        #expect(!list.contains { $0.parametersB > 4.0 })
        #expect(catalog.defaultModel(on: .iPad(largeMemory: true))?.id == catalog.defaultModel?.id)
    }

    @Test func iPadMemoryThreshold() {
        #expect(ModelCatalog.Device.iPad(physicalMemory: 8 * 1_073_741_824) == .iPad(largeMemory: true))
        #expect(ModelCatalog.Device.iPad(physicalMemory: 6 * 1_073_741_824) == .iPad(largeMemory: false))
    }
}

@Suite struct ModelMemoryGateTests {
    let small = ModelCatalog.bundled()!.models.first { $0.parametersB <= 2.0 }!

    @Test func refusesWhenShort() {
        let need = ModelMemoryGate.bytesNeeded(forModelOfSize: small.sizeBytes)
        #expect(need > small.sizeBytes)
        #expect(ModelMemoryGate.refusal(for: small, available: need) == nil)
        let why = ModelMemoryGate.refusal(for: small, available: need - 1)
        #expect(why?.contains(small.name) == true)
        #expect(why?.contains("smaller model") == true)
    }

    @Test func memoryEstimateScalesWithContextWindow() {
        let fourK = ModelMemoryGate.bytesNeeded(forModelOfSize: small.sizeBytes, contextTokens: 4096)
        let eightK = ModelMemoryGate.bytesNeeded(forModelOfSize: small.sizeBytes, contextTokens: 8192)
        #expect(eightK - small.sizeBytes - 256 * 1_048_576 == 2 * (fourK - small.sizeBytes - 256 * 1_048_576))
        #expect(ModelMemoryGate.bytesNeeded(forModelOfSize: small.sizeBytes, contextTokens: 1024) == fourK)
        #if os(iOS)
        #expect(ModelMemoryGate.defaultContextTokens == 8192)
        #else
        #expect(ModelMemoryGate.defaultContextTokens == 16384)
        #endif
        let runtimeNeed = ModelMemoryGate.bytesNeeded(forModelOfSize: small.sizeBytes, contextTokens: ModelMemoryGate.defaultContextTokens)
        #expect(ModelMemoryGate.bytesNeeded(forModelOfSize: small.sizeBytes) == runtimeNeed)
        #expect(ModelMemoryGate.refusal(for: small, available: runtimeNeed - 1) != nil)
        #expect(ModelMemoryGate.refusal(for: small, available: runtimeNeed) == nil)
    }
}
