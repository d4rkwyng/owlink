import Foundation
import CedricCore

/// Cedric's pick among the spell checker's guesses (0.5.3): for a
/// misspelled word with two or more plausible guesses (wich → with / which
/// / wish), the model may only choose one of them for the sentence. The
/// result only reorders the guesses Fix Typos shows; nothing is applied.
///
/// Runs only for an Ask the user made, with an engine already in use for
/// it (`engineInUse`); the built-in engine must also have its model loaded
/// already: the picker never starts a model load. It times out quickly,
/// and any failure, timeout or answer not in the list keeps the spell
/// checker's order.
///
/// - Built-in engine: decoded under a GBNF grammar of exactly the
///   candidates (`OwlSpellingChoice.grammar`).
/// - LM Studio / Ollama and others: the answer is validated
///   (`OwlSpellingChoice.validate`).
public enum OwlSpellingPicker {
    public static let timeout: TimeInterval = 2.5
    static let maxTokens = 16

    /// `guesses` reordered by Cedric's pick, or unchanged.
    public static func pick(word: String, sentence: String, guesses: [String], engine: (any OwlChatEngine)?,
                            engineInUse: Bool, timeout: TimeInterval = timeout) async -> [String] {
        let candidates = OwlSpellingChoice.plausible(guesses, for: word)
        guard engineInUse, let engine, candidates.count >= 2 else { return guesses }
        if let b = engine as? BuiltInChatEngine, await b.host.loadedPath != b.path { return guesses }
        let answer = await withTaskGroup(of: String?.self) { group -> String? in
            group.addTask { try? await ask(word: word, sentence: sentence, candidates: candidates, engine: engine) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        guard let answer, let chosen = OwlSpellingChoice.validate(answer, candidates: candidates) else { return guesses }
        return OwlSpellingChoice.reorder(guesses, pick: chosen)
    }

    /// The model's raw answer.
    static func ask(word: String, sentence: String, candidates: [String], engine: any OwlChatEngine) async throws -> String {
        let p = OwlSpellingChoice.prompt(word: word, sentence: sentence, candidates: candidates)
        if let b = engine as? BuiltInChatEngine {
            let request = GenerationRequest(system: p.system, user: p.user, maxTokens: maxTokens,
                                            grammar: OwlSpellingChoice.grammar(candidates))
            return try await b.host.generate(modelAt: b.path, request) { _ in }.text
        }
        let turn = try await engine.turn([.system(p.system), .user(p.user)], tools: [], toolbox: nil, maxTokens: maxTokens) { _ in }
        guard case .answer(let a) = turn else { return "" }
        return a
    }
}
