import Foundation
import CedricCore

/// Cedric's own engine: a GGUF model downloaded from Hugging Face into
/// `~/Library/Application Support/Cedric/Models/` and run in-process by
/// llama.cpp. No LM Studio, no server, nothing leaves the Mac after the
/// download. The prompts are the shared `OwlPrompts`.
public struct BuiltInEngine: AIEngine {
    public let catalog: ModelCatalog?
    public let store: ModelStore
    public let host: BuiltInModelHost

    public init(catalog: ModelCatalog? = ModelCatalog.bundled(), store: ModelStore = ModelStore(),
                host: BuiltInModelHost = .shared) {
        self.catalog = catalog
        self.store = store
        self.host = host
    }

    public var kind: LocalAISettings.Backend { .builtIn }
    public var isAvailable: Bool { catalog != nil }
    public var unavailableReason: String? {
        catalog == nil ? "This copy of Owlink is missing its model list (Resources/AI/models.json)." : nil
    }
    public var needsAddress: Bool { false }
    public var note: String? {
        LlamaRuntime.isSlowHardware
            ? "Slow on Intel Macs: the built-in model runs on the CPU here. Another Mac on your network will be much faster."
            : nil
    }

    /// The downloaded (installed) models, in catalog order.
    public var installedModels: [BuiltInModel] { catalog.map(store.installed(in:)) ?? [] }

    public func models() async throws -> [LocalModelInfo] { installedModels.map(\.info) }

    /// Loads the model (if needed) and runs a one-word prompt: proves the
    /// file, the runtime and Metal work, and how long a first answer takes.
    public func test() async -> ConnectionReport {
        let infos = installedModels.map(\.info)
        let suggested = suggestedModel(in: infos)
        guard let pick = suggested.flatMap({ catalog?.model(id: $0.id) }) else {
            return ConnectionReport(models: infos, latency: 0, suggested: nil,
                                    error: .transport("no model downloaded yet"))
        }
        let start = Date()
        do {
            // Test Connection is the user asking.
            _ = try await BuiltInLoad.userAsked {
                try await host.generate(modelAt: store.fileURL(for: pick),
                                        GenerationRequest(system: OwlPrompts.persona, user: "Reply with the word ready.", maxTokens: 4))
            }
            return ConnectionReport(models: infos, latency: Date().timeIntervalSince(start), suggested: suggested, error: nil)
        } catch {
            return ConnectionReport(models: infos, latency: Date().timeIntervalSince(start), suggested: suggested,
                                    error: .transport(String(describing: error)))
        }
    }

    /// The catalog default if downloaded, else the first downloaded model
    /// that fits this Mac's memory.
    public func suggestedModel(in models: [LocalModelInfo]) -> LocalModelInfo? {
        guard let catalog else { return nil }
        let ids = Set(models.map(\.id))
        if let d = catalog.defaultModel, ids.contains(d.id) { return d.info }
        return catalog.models.first { ids.contains($0.id) && !$0.needsMoreMemory() }?.info
            ?? catalog.models.first { ids.contains($0.id) }?.info
    }

    public func makeProvider(model: String?) async -> (any OwlHintProvider)? {
        guard let catalog else { return nil }
        let installed = installedModels
        let chosen: BuiltInModel?
        if let model, !model.isEmpty {
            chosen = installed.first { $0.id == model }
        } else {
            chosen = suggestedModel(in: installed.map(\.info)).flatMap { catalog.model(id: $0.id) }
        }
        guard let chosen else { return nil }
        return BuiltInHintProvider(model: chosen, path: store.fileURL(for: chosen), host: host)
    }
}

/// The owl's hints from the built-in engine. Same prompt, same parser and
/// the same `local:<model>` source as the server engines; the output is
/// additionally constrained by a JSON grammar, so a small model can't
/// answer in prose.
public struct BuiltInHintProvider: OwlHintProvider, OwlAutomaticGate, OwlPreloadingProvider {
    public let model: BuiltInModel
    public let path: URL
    public let host: BuiltInModelHost
    public let maxTokens: Int

    public init(model: BuiltInModel, path: URL, host: BuiltInModelHost, maxTokens: Int = 320) {
        self.model = model; self.path = path; self.host = host; self.maxTokens = maxTokens
    }

    public var name: String { "local:\(model.id)" }

    /// Automatic checks only once the user (or "Load model at launch")
    /// has loaded a model this session, and not after a load hung.
    public var allowsAutomaticRequests: Bool { host.session.allowsAutomatic }
    public var isUnhealthy: Bool { host.session.unhealthy != nil }

    /// "Load model at launch": off the main thread, under the watchdog.
    public func preload() async throws { try await host.preload(modelAt: path) }

    public func hints(for context: OwlContext) async -> [OwlHint] {
        (try? await requestHints(for: context).hints) ?? []
    }

    public func request(for context: OwlContext) -> (request: GenerationRequest, text: String) {
        let text = HintPrompt.capped(context.text)
        let messages = OwlPrompts.messages(for: .codeHints, context: context, text: text, model: model.promptModelName)
        let system = messages.first { $0.role == "system" }?.content ?? ""
        let user = messages.first { $0.role == "user" }?.content ?? ""
        return (GenerationRequest(system: system, user: user, maxTokens: maxTokens, grammar: HintGrammar.gbnf), text)
    }

    /// The throwing variant with the raw result, for "Test" and the live check.
    public func requestHints(for context: OwlContext) async throws -> (hints: [OwlHint], result: GenerationResult) {
        guard HintPrompt.hasEnoughText(context.text) else { return ([], GenerationResult(text: "")) }
        let (request, text) = request(for: context)
        do {
            let result = try await host.generate(modelAt: path, request)
            try Task.checkCancellation()
            let hints = HintPrompt.parse(result.content, text: text, source: name, language: context.language,
                                     wholeDocument: context.isWholeDocument)
            AILog.logger.info("""
                owl-ai ok engine=builtin model=\(model.id, privacy: .public) gen=\(context.editGeneration) \
                promptTokens=\(result.promptTokens) completionTokens=\(result.completionTokens) \
                latencyMs=\(Int((result.promptSeconds + result.generateSeconds) * 1000)) hints=\(hints.count)
                """)
            return (hints, result)
        } catch {
            AILog.logger.info("owl-ai error engine=builtin model=\(model.id, privacy: .public) gen=\(context.editGeneration)")
            throw error
        }
    }
}

extension GenerationResult {
    var content: String { text }
}

/// GBNF for the hint JSON (the same shape as `HintPrompt.schema`): at most
/// two hints, the four kinds, numeric confidence, bounded whitespace.
public enum HintGrammar {
    public static let gbnf = #"""
    root ::= "{" ws "\"hints\"" ws ":" ws "[" ws ( hint ( ws "," ws hint )? )? ws "]" ws "}"
    hint ::= "{" ws "\"kind\"" ws ":" ws kind ws "," ws "\"category\"" ws ":" ws category ws "," ws "\"title\"" ws ":" ws string ws "," ws "\"detail\"" ws ":" ws string ws "," ws "\"line\"" ws ":" ws line ws "," ws "\"find\"" ws ":" ws string ws "," ws "\"replacement\"" ws ":" ws string ws "," ws "\"confidence\"" ws ":" ws number ws "}"
    kind ::= "\"fix\"" | "\"warning\"" | "\"tip\"" | "\"explain\""
    category ::= "\"unclosed-tag\"" | "\"brackets\"" | "\"unused\"" | "\"undefined\"" | "\"json\"" | "\"logic\"" | "\"other\""
    line ::= [1-9] [0-9]? [0-9]? [0-9]?
    string ::= "\"" char* "\""
    char ::= [^"\\\x00-\x1F] | "\\" ( ["\\/bfnrt] | "u" [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] [0-9a-fA-F] )
    number ::= ( "0" ( "." [0-9] [0-9]? )? ) | ( "1" ( "." "0" "0"? )? )
    ws ::= [ \t\n]? [ \t\n]? [ \t\n]?
    """#
}
