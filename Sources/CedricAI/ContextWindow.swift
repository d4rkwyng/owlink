import Foundation
import os

/// A model's context window (tokens) as Ask Cedric's budget (UTF-16 units
/// of prompt, history and numbered document text, `OwlChatEngine.contextBudget`).
/// One conversion for every engine that knows its window, so the built-in
/// engine's budget and its runtime's prompt limit come from the same n_ctx.
public enum ContextWindow {
    /// Tokens kept free for the answer (Ask Cedric asks for at most 700;
    /// the grammar pass 500) and the chat template's own tokens.
    public static let replyReserveTokens = 1_024

    /// What a window leaves for the prompt, in budget units: 1.5 units per
    /// token. The 0.5.1 numbers (16 384 tokens → 24 000 units, 4096 →
    /// 6000) were 1.46 units per token with nothing held back for the
    /// answer; this keeps the reply reserve out first.
    public static func budgetUnits(contextTokens: Int) -> Int {
        max(0, contextTokens - replyReserveTokens) * 3 / 2
    }

    // MARK: Servers

    /// The most a server request gets, whatever the server's window.
    public static let serverCap = 32_000

    /// The server engine's budget: the cap, or less when the server's
    /// window is known to be smaller. Unknown (an OpenAI-compatible server
    /// that says nothing): the cap, as before 0.5.3.
    public static func serverBudget(contextTokens: Int?) -> Int {
        guard let contextTokens else { return serverCap }
        return min(serverCap, budgetUnits(contextTokens: contextTokens))
    }

    // MARK: Built-in (llama.cpp)

    /// n_ctx choices for the built-in engine, largest first; the last is
    /// the floor every supported Mac gets.
    public static let builtInSteps: [Int] = [16_384, 8_192, 4_096]

    /// The share of physical memory the model's weights, KV cache and
    /// compute buffers may take together (the rest is macOS, Owlink and
    /// the user's other apps; Metal's working-set limit is higher).
    public static let builtInMemoryShare = 0.5

    /// llama.cpp's compute buffers and the rest of a context besides the
    /// KV cache, at n_batch 512 (measured ≈ 300 MB for the 4B models).
    public static let builtInOverheadBytes: Int64 = 512 * 1_048_576

    /// The largest step whose weights + f16 KV cache + overhead fit in
    /// `builtInMemoryShare` of `physicalMemory`; else the floor.
    public static func builtInContextTokens(modelBytes: Int64, kvBytesPerToken: Int64,
                                            physicalMemory: UInt64) -> Int {
        let allowed = Double(physicalMemory) * builtInMemoryShare
        for steps in builtInSteps.dropLast() {
            let need = Double(modelBytes) + Double(kvBytesPerToken) * Double(steps) + Double(builtInOverheadBytes)
            if need <= allowed { return steps }
        }
        return builtInSteps.last!
    }

    static let logger = Logger(subsystem: "net.mindtricks.cedric", category: "owl-ai")
}

extension BuiltInModel {
    /// f16 KV cache bytes per token: the catalog's figure (2 × layers ×
    /// KV heads × head size × 2 bytes), else a generous guess from the
    /// parameter count (40 KB per billion; Qwen3 4B is 36 KB per billion).
    public var kvCacheBytesPerToken: Int64 {
        kvBytesPerToken ?? Int64(parametersB * 40_960)
    }

    /// The n_ctx the built-in engine uses for this model on this Mac.
    public func contextTokens(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        ContextWindow.builtInContextTokens(modelBytes: sizeBytes, kvBytesPerToken: kvCacheBytesPerToken,
                                           physicalMemory: physicalMemory)
    }
}
