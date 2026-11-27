import Foundation

/// One downloadable model for the built-in engine, as `Resources/AI/models.json`
/// lists it. Every download is pinned: a Hugging Face URL at a fixed
/// revision, its exact byte size and its SHA-256.
public struct BuiltInModel: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    /// "qwen2.5-coder", "qwen3", "qwen3-instruct-2507": picks prompt quirks
    /// (anything containing "qwen3" gets /no_think; harmless for 2507 Instruct).
    public var family: String
    public var parametersB: Double
    public var quantization: String
    public var fileName: String
    public var sizeBytes: Int64
    public var url: URL
    /// The Hugging Face commit the URL is pinned to.
    public var revision: String
    /// Lower-case hex SHA-256 of the whole file.
    public var sha256: String
    public var license: String
    public var licenseURL: URL
    /// Below this much physical memory the model is marked "needs more memory".
    public var minRAMGB: Int
    public var isDefault: Bool
    /// f16 KV-cache bytes per token of context (2 × layers × KV heads ×
    /// head size × 2), for choosing n_ctx (`contextTokens`). Optional:
    /// without it a guess from `parametersB` is used.
    public var kvBytesPerToken: Int64?

    public init(id: String, name: String, summary: String = "", family: String, parametersB: Double,
                quantization: String, fileName: String, sizeBytes: Int64, url: URL, revision: String,
                sha256: String, license: String, licenseURL: URL, minRAMGB: Int = 8, isDefault: Bool = false,
                kvBytesPerToken: Int64? = nil) {
        self.id = id; self.name = name; self.summary = summary; self.family = family
        self.parametersB = parametersB; self.quantization = quantization; self.fileName = fileName
        self.sizeBytes = sizeBytes; self.url = url; self.revision = revision; self.sha256 = sha256
        self.license = license; self.licenseURL = licenseURL; self.minRAMGB = minRAMGB; self.isDefault = isDefault
        self.kvBytesPerToken = kvBytesPerToken
    }

    /// The id handed to the prompt builder; it contains "qwen3" for Qwen3,
    /// which is how `OwlPrompts` knows to add `/no_think`.
    public var promptModelName: String { family + "-" + id }

    public var isNonCommercial: Bool { license.localizedCaseInsensitiveContains("non-commercial") }

    /// Reads the license text shipped with Cedric. This never performs a
    /// network request; nil means the bundled/source-tree file is missing.
    public func bundledLicenseText(bundle: Bundle = .main) -> String? {
        guard let url = ModelCatalog.bundledLicenseURL(for: license, bundle: bundle) else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    public func licenseConfirmation(bundle: Bundle = .main) -> BuiltInModelLicenseConfirmation? {
        guard let text = bundledLicenseText(bundle: bundle) else { return nil }
        let warning = isNonCommercial ? "NON-COMMERCIAL LICENSE\n\n" : ""
        return BuiltInModelLicenseConfirmation(title: name, licenseName: license, body: warning + text,
                                               isNonCommercial: isNonCommercial)
    }

    /// "3.1B · Q4_K_M · 2.1 GB"
    public var shortDescription: String {
        let gb = Double(sizeBytes) / 1_000_000_000
        return String(format: "%gB · %@ · %.1f GB", parametersB, quantization, gb)
    }

    /// True when this Mac has less memory than the model wants.
    public func needsMoreMemory(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Bool {
        physicalMemory < UInt64(minRAMGB) * 1_073_741_824
    }

    /// As Settings › Cedric's model list wants it.
    public var info: LocalModelInfo {
        LocalModelInfo(id: id, sizeBytes: sizeBytes, parametersB: parametersB,
                       quantization: quantization, type: "llm")
    }
}

public struct BuiltInModelLicenseConfirmation: Sendable, Equatable {
    public let title: String
    public let licenseName: String
    public let body: String
    public let isNonCommercial: Bool
}

public enum ModelCatalogError: Error, Equatable, Sendable {
    case missing
    case malformed(String)
    case invalid(String)
}

/// The curated list of models Cedric offers to download. Shipped as JSON in
/// the app bundle (`Contents/Resources/AI/models.json`); nothing is fetched
/// to learn what can be downloaded.
public struct ModelCatalog: Codable, Sendable, Equatable {
    public var version: Int
    /// The llama.cpp build the list was tested with (informational).
    public var runtime: String
    public var models: [BuiltInModel]

    public init(version: Int = 1, runtime: String = "", models: [BuiltInModel]) {
        self.version = version; self.runtime = runtime; self.models = models
    }

    /// The only host a model may be downloaded from (redirects to its CDN
    /// are followed by URLSession; the request itself starts here).
    public static let allowedHost = "huggingface.co"

    public var defaultModel: BuiltInModel? { models.first(where: \.isDefault) ?? models.first }

    public func model(id: String?) -> BuiltInModel? {
        guard let id else { return nil }
        return models.first { $0.id == id }
    }

    /// What kind of device the catalog is offered on.
    public enum Device: Sendable, Equatable {
        case mac
        case iPhone
        /// `largeMemory`: 8 GB or more (the M-series iPads).
        case iPad(largeMemory: Bool)

        /// iPads with 8 GB or more are the M-series ones.
        public static func iPad(physicalMemory: UInt64) -> Device {
            .iPad(largeMemory: physicalMemory >= 7_500_000_000)
        }
    }

    /// The models offered for download on `device`. A Mac gets the whole
    /// list. iOS's per-app memory limit is far below the device's RAM, so an
    /// iPhone (and an iPad without an M chip) gets only the small models
    /// (up to 2B parameters, about 1 GB), and an M-series iPad also the 3–4B
    /// ones. Never the 7B.
    public func offered(on device: Device) -> [BuiltInModel] {
        switch device {
        case .mac: return models
        case .iPhone, .iPad(largeMemory: false): return models.filter { $0.parametersB <= 2.0 }
        case .iPad(largeMemory: true): return models.filter { $0.parametersB <= 4.0 }
        }
    }

    /// The model suggested first on `device`: the catalog's default if it is
    /// offered there, else the smallest offered one.
    public func defaultModel(on device: Device) -> BuiltInModel? {
        let list = offered(on: device)
        if let d = defaultModel, list.contains(d) { return d }
        return list.min { $0.sizeBytes < $1.sizeBytes }
    }

    /// Decodes and validates: exactly one default, unique ids and file
    /// names, https on huggingface.co pinned to the listed revision, a
    /// 64-hex SHA-256, a positive size, a `.gguf` file name with no path.
    public static func decode(_ data: Data) throws -> ModelCatalog {
        let catalog: ModelCatalog
        do { catalog = try JSONDecoder().decode(ModelCatalog.self, from: data) } catch {
            throw ModelCatalogError.malformed(String(describing: error))
        }
        try catalog.validate()
        return catalog
    }

    public func validate() throws {
        guard !models.isEmpty else { throw ModelCatalogError.invalid("no models") }
        guard models.filter(\.isDefault).count == 1 else { throw ModelCatalogError.invalid("needs exactly one default") }
        guard Set(models.map(\.id)).count == models.count else { throw ModelCatalogError.invalid("duplicate id") }
        guard Set(models.map(\.fileName)).count == models.count else { throw ModelCatalogError.invalid("duplicate file") }
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for m in models {
            guard m.url.scheme == "https", m.url.host == Self.allowedHost else {
                throw ModelCatalogError.invalid("\(m.id): not an https huggingface.co URL")
            }
            guard m.url.path.contains("/resolve/\(m.revision)/"), m.revision.count == 40 else {
                throw ModelCatalogError.invalid("\(m.id): URL not pinned to its revision")
            }
            guard m.url.lastPathComponent == m.fileName, m.fileName.hasSuffix(".gguf"),
                  !m.fileName.contains("/"), !m.fileName.hasPrefix(".") else {
                throw ModelCatalogError.invalid("\(m.id): bad file name")
            }
            guard m.sha256.count == 64, m.sha256.unicodeScalars.allSatisfy(hex.contains) else {
                throw ModelCatalogError.invalid("\(m.id): bad sha256")
            }
            guard m.sizeBytes > 0, m.parametersB > 0 else { throw ModelCatalogError.invalid("\(m.id): bad size") }
            if let kv = m.kvBytesPerToken, kv <= 0 { throw ModelCatalogError.invalid("\(m.id): bad kvBytesPerToken") }
        }
    }

    /// Where the JSON lives: the app bundle, else (swift run / tests) the
    /// source tree's `Resources/AI/models.json`.
    public static func bundledURL(bundle: Bundle = .main) -> URL? {
        if let url = bundle.url(forResource: "models", withExtension: "json", subdirectory: "AI") { return url }
        let source = URL(fileURLWithPath: #filePath)   // …/Sources/CedricAI/BuiltIn/ModelCatalog.swift
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AI/models.json")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// The license field determines which bundled text is shown.
    public static func bundledLicenseURL(for license: String, bundle: Bundle = .main) -> URL? {
        let fileName = license.localizedCaseInsensitiveContains("non-commercial")
            ? "Qwen-Research-License" : "Apache-2.0"
        if let url = bundle.url(forResource: fileName, withExtension: "txt", subdirectory: "AI/licenses") { return url }
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/AI/licenses/\(fileName).txt")
        return FileManager.default.fileExists(atPath: source.path) ? source : nil
    }

    /// The bundled catalog, or nil if it is missing or invalid.
    public static func bundled(bundle: Bundle = .main) -> ModelCatalog? {
        guard let url = bundledURL(bundle: bundle), let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }
}
