import Foundation
import CedricCore

// Apple's on-device model (Foundation Models framework, macOS 26+, Apple
// silicon with Apple Intelligence turned on). Only `SystemLanguageModel` is
// used: it runs on the device. The SDK also has a Private Cloud Compute
// model; that is a network service and is deliberately NOT used.
//
// Guided generation: `@Generable` needs the FoundationModelsMacros compiler
// plugin, which ships with Xcode, not the Command Line Tools Cedric builds
// with. The same constraint is expressed at run time instead, as a
// `DynamicGenerationSchema` with the hint fields, the four kinds as an enum
// and at most two hints; the reply comes back as JSON and goes through the
// shared `HintPrompt.parse`.
//
// Toolchain note: CI builds with Swift 6.1 against the macOS 15 SDK, which
// has no FoundationModels module, so `canImport` is false there and only the
// placeholder below compiles (Intel too). `status` gates at run time: OS
// version, Apple silicon, Apple Intelligence on, model downloaded.

/// Why Apple Intelligence can or can't run the owl here.
public enum AppleIntelligenceStatus: String, Sendable, Equatable {
    case available
    case osTooOld            // before macOS 26
    case unsupported         // no FoundationModels in this build, or Intel
    case deviceNotEligible
    case notEnabled          // Apple Intelligence is off in System Settings
    case modelNotReady       // still downloading / preparing
    case unknown

    public var message: String? {
        switch self {
        case .available: return nil
        #if os(iOS)
        case .osTooOld, .unsupported: return "Needs iOS 26 or later on a device that supports Apple Intelligence."
        case .deviceNotEligible: return "This device can’t run Apple Intelligence."
        case .notEnabled: return "Turn on Apple Intelligence in Settings to use it."
        #else
        case .osTooOld, .unsupported: return "Needs macOS 26 or later on Apple silicon."
        case .deviceNotEligible: return "This Mac can’t run Apple Intelligence."
        case .notEnabled: return "Turn on Apple Intelligence in System Settings to use it."
        #endif
        case .modelNotReady: return "Apple Intelligence is still getting its model ready. Try again later."
        case .unknown: return "Apple Intelligence isn’t available right now."
        }
    }
}

#if canImport(FoundationModels) && arch(arm64)
import FoundationModels

public struct AppleFoundationModelsProvider: OwlHintProvider {
    public var name: String { "apple" }
    /// The on-device model's context is small (4K tokens on macOS 26); the
    /// owl's 8 KB is trimmed to this so instructions + schema + code + answer fit.
    public static let maxContextBytes = 6 * 1024
    public static let maxResponseTokens = 400

    public init() {}

    public static var status: AppleIntelligenceStatus {
        // Test hook: CEDRIC_SIMULATE_NO_APPLE_INTELLIGENCE=1 reports this Mac
        // as a CI VM does, to run the suite as on a Mac without Apple Intelligence.
        if DevEnvironment.values["CEDRIC_SIMULATE_NO_APPLE_INTELLIGENCE"] == "1" { return .deviceNotEligible }
        guard #available(macOS 26.0, iOS 26.0, *) else { return .osTooOld }
        switch SystemLanguageModel.default.availability {
        case .available: return .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return .deviceNotEligible
            case .appleIntelligenceNotEnabled: return .notEnabled
            case .modelNotReady: return .modelNotReady
            @unknown default: return .unknown
            }
        @unknown default: return .unknown
        }
    }

    public static var isAvailable: Bool { status == .available }

    public func hints(for context: OwlContext) async -> [OwlHint] {
        (try? await requestHints(for: context).hints) ?? []
    }

    /// The throwing variant with the raw JSON and the latency, for the live check.
    public func requestHints(for context: OwlContext) async throws -> (hints: [OwlHint], raw: String, seconds: TimeInterval) {
        guard HintPrompt.hasEnoughText(context.text) else { return ([], "", 0) }
        guard #available(macOS 26.0, iOS 26.0, *), Self.isAvailable else { throw LocalAIError.transport("Apple Intelligence unavailable") }
        let text = HintPrompt.capped(context.text, maxBytes: Self.maxContextBytes)
        let messages = OwlPrompts.messages(for: .codeHints, context: context, text: text, model: "apple")
        let system = messages.first { $0.role == "system" }?.content ?? ""
        let user = messages.first { $0.role == "user" }?.content ?? ""
        // A fresh session per request: no transcript is kept between checks.
        let session = LanguageModelSession(model: SystemLanguageModel.default, instructions: system)
        let start = Date()
        let response = try await session.respond(to: user, schema: try Self.schema(),
                                                 options: GenerationOptions(temperature: 0, maximumResponseTokens: Self.maxResponseTokens))
        try Task.checkCancellation()
        let raw = response.content.jsonString
        let seconds = Date().timeIntervalSince(start)
        let hints = HintPrompt.parse(raw, text: text, source: name, language: context.language,
                                     wholeDocument: context.isWholeDocument)
        AILog.logger.info("owl-ai ok engine=apple gen=\(context.editGeneration) latencyMs=\(Int(seconds * 1000)) hints=\(hints.count)")
        return (hints, raw, seconds)
    }

    /// `{"hints":[{kind,title,detail,find,replacement,confidence}]}`, ≤ 2 hints.
    @available(macOS 26.0, iOS 26.0, *)
    static func schema() throws -> GenerationSchema {
        let string = DynamicGenerationSchema(type: String.self)
        let hint = DynamicGenerationSchema(name: "Hint", properties: [
            .init(name: "kind", description: "fix: a bug with a fix; warning: a likely bug; tip; explain",
                  schema: DynamicGenerationSchema(name: "Kind", anyOf: ["fix", "warning", "tip", "explain"])),
            .init(name: "category", description: "what kind of problem",
                  schema: DynamicGenerationSchema(name: "Category", anyOf: HintVerifier.Category.modelCases.map(\.rawValue))),
            .init(name: "title", description: "names the specific problem in a few words", schema: string),
            .init(name: "detail", description: "one or two plain sentences on why it is wrong", schema: string),
            .init(name: "line", description: "the line number the problem is on", schema: DynamicGenerationSchema(type: Int.self)),
            .init(name: "find", description: "the exact snippet from that line, without the line number", schema: string),
            .init(name: "replacement", description: "the corrected snippet that replaces find whenever it can be fixed; empty only if there is no safe fix", schema: string),
            .init(name: "confidence", description: "0.0 to 1.0", schema: DynamicGenerationSchema(type: Double.self)),
        ])
        let root = DynamicGenerationSchema(name: "Hints", properties: [
            .init(name: "hints", schema: DynamicGenerationSchema(arrayOf: hint, minimumElements: 0, maximumElements: HintPrompt.maxHints)),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }
}

#else

/// Placeholder where the Foundation Models SDK isn't present (CI's Swift 6.1
/// toolchain, Intel): never available, returns no hints.
public struct AppleFoundationModelsProvider: OwlHintProvider {
    public var name: String { "apple" }
    public init() {}
    public static var status: AppleIntelligenceStatus { .unsupported }
    public static var isAvailable: Bool { false }
    public func hints(for context: OwlContext) async -> [OwlHint] { [] }
}

#endif
