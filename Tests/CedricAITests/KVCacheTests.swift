import Foundation
import Testing
@testable import CedricAI

/// KV-cache reuse across requests (`LlamaModel.cachePlan`), without
/// llama.cpp: the decision of how much of the cache to keep. The real
/// cache is measured in LiveKVCacheTests (CEDRIC_KV_LIVE=1).
@Suite struct KVCacheTests {
    @Test func keepsTheCommonPrefixButAlwaysDecodesOneToken() {
        #expect(LlamaModel.reusablePrefix(cached: [1, 2, 3, 4], prompt: [1, 2, 3, 9, 9]) == 3)
        // The new prompt extends the cache (a tool round appended).
        #expect(LlamaModel.reusablePrefix(cached: [1, 2, 3], prompt: [1, 2, 3, 4, 5]) == 3)
        // The same prompt again: its last token is decoded again for its logits.
        #expect(LlamaModel.reusablePrefix(cached: [1, 2, 3], prompt: [1, 2, 3]) == 2)
        // A shorter prompt inside the cache.
        #expect(LlamaModel.reusablePrefix(cached: [1, 2, 3, 4, 5], prompt: [1, 2]) == 1)
        #expect(LlamaModel.reusablePrefix(cached: [7, 2], prompt: [1, 2]) == 0)
        #expect(LlamaModel.reusablePrefix(cached: [], prompt: [1, 2]) == 0)
        #expect(LlamaModel.reusablePrefix(cached: nil as [Int]?, prompt: [1, 2]) == 0)
        #expect(LlamaModel.reusablePrefix(cached: [1], prompt: [1]) == 0)
    }

    final class Memory {
        var firstPosition = 0
        var lastPosition: Int
        var removedFrom: [Int] = []
        let canCut: Bool
        init(holding n: Int, canCut: Bool = true) { lastPosition = n - 1; self.canCut = canCut }
    }

    static func plan(_ cached: [Int]?, _ prompt: [Int], memory m: Memory, reuse: Bool = true) -> (keep: Int, refused: Bool) {
        LlamaModel.cachePlan(cached: cached, prompt: prompt, reuse: reuse, positions: { (m.firstPosition, m.lastPosition) },
                             removeFrom: { p in m.removedFrom.append(p); return m.canCut })
    }

    @Test func cutsTheCacheAfterTheSharedPrefix() {
        let m = Memory(holding: 6)
        let p = Self.plan([1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 7, 8, 9], memory: m)
        #expect(p.keep == 4 && !p.refused)
        #expect(m.removedFrom == [4])
    }

    @Test func clearsWhenReuseIsOffUnknownOrNothingIsShared() {
        let m = Memory(holding: 3)
        #expect(Self.plan([1, 2, 3], [1, 2, 3, 4], memory: m, reuse: false).keep == 0)
        #expect(Self.plan(nil, [1, 2, 3, 4], memory: m).keep == 0)
        #expect(Self.plan([9, 9, 9], [1, 2, 3, 4], memory: m).keep == 0)
        #expect(m.removedFrom.isEmpty, "nothing is cut when the whole cache goes")
    }

    @Test func clearsWhenTheCacheIsNotWhatWasRecorded() {
        // A decode that failed half-way leaves more (or fewer) positions.
        let m = Memory(holding: 5)
        let p = Self.plan([1, 2, 3], [1, 2, 3, 4], memory: m)
        #expect(p.keep == 0 && !p.refused)
        #expect(m.removedFrom.isEmpty)
    }

    @Test func clearsASlidingWindowCacheThatDroppedEarlyPositions() {
        let m = Memory(holding: 6)
        m.firstPosition = 2
        let p = Self.plan([1, 2, 3, 4, 5, 6], [1, 2, 3, 4, 7], memory: m)
        #expect(p.keep == 0 && p.refused)
    }

    @Test func recurrentAppendStillClears() {
        // Nothing to remove (the prompt extends the cache), but a recurrent
        // cache's first position is its last one: cleared, not trusted.
        let m = Memory(holding: 3)
        m.firstPosition = 2
        #expect(Self.plan([1, 2, 3], [1, 2, 3, 4], memory: m) == (0, true))
    }

    @Test func hybridOrRecurrentMemoryThatRefusesFallsBackToAFullClear() {
        // llama_memory_seq_rm returns false: a partial sequence can't be removed.
        let m = Memory(holding: 4, canCut: false)
        let p = Self.plan([1, 2, 3, 4], [1, 2, 9], memory: m)
        #expect(p.keep == 0 && p.refused)
        #expect(m.removedFrom == [2])
    }

    @Test func resultsReportReusedTokens() {
        let r = GenerationResult(text: "x", promptTokens: 900, completionTokens: 10, reusedTokens: 850)
        #expect(r.reusedTokens == 850)
        #expect(GenerationResult(text: "x").reusedTokens == 0)
    }
}

/// Quit after a warm-up the watchdog gave up on. The model is registered
/// for exit before its warm-up decode; if that decode never returns (a
/// GPU that hung, the abort flag never read), the exit hook used to wait
/// on llama.cpp's queue with no limit, behind it: Quit hung. The hook now
/// waits at most `LlamaModel.exitWait`. Without llama.cpp: a plain queue
/// blocked by a semaphore stands in for the hung decode.
@Suite struct LlamaExitWaitTests {
    @Test func exitFreesOnAQueueThatIsFree() {
        let q = DispatchQueue(label: "cedric.test.exit-free")
        let ran = Box(false)
        #expect(LlamaModel.runBounded(on: q, timeout: 5) { ran.mutate { $0 = true } })
        #expect(ran.value)
    }

    @Test func exitDoesNotWaitForeverBehindAHungDecode() {
        let q = DispatchQueue(label: "cedric.test.exit-blocked")
        let hung = DispatchSemaphore(value: 0)
        q.async { hung.wait() }   // the warm-up decode that never returns
        let ran = Box(false)
        let t0 = Date()
        #expect(!LlamaModel.runBounded(on: q, timeout: 0.2) { ran.mutate { $0 = true } })
        #expect(Date().timeIntervalSince(t0) < 4, "gave up after its limit, not when the queue freed")
        #expect(!ran.value, "nothing was freed under a running decode")
        hung.signal()
        q.sync {}
        #expect(ran.value)
    }

    @Test func theExitWaitIsShortButNotZero() {
        #expect(LlamaModel.exitWait > 0 && LlamaModel.exitWait <= 10)
    }
}
