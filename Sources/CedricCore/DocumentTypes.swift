import Foundation
import UniformTypeIdentifiers

/// The text file types Owlink declares in Info.plist, each with its own
/// document icon, and that Settings › Default editor for… lists.
/// Resources/document-types.txt is the copy Scripts/bundle-app.sh builds
/// Info.plist from; DocumentTypesTests keeps the two in step.
public struct DocumentFileType: Sendable, Hashable, Identifiable {
    /// The label on the icon ("MD").
    public let label: String
    /// The icon's file name in Contents/Resources, without ".icns".
    public let icon: String
    /// What Settings calls it ("Markdown").
    public let name: String
    /// The content types the document type claims. Settings makes Owlink
    /// the default for all of them; the first is the one it shows.
    public let contentTypes: [String]
    /// For the types macOS doesn't declare: what Owlink's imported
    /// declaration says.
    public let imported: Imported?
    /// The entry's LSHandlerRank. Alternate only for 0.2.x's exact claims
    /// (see Resources/document-types.txt).
    public let rank: Rank

    public enum Rank: String, Sendable, Hashable {
        case none = "None"
        case alternate = "Alternate"
    }

    public struct Imported: Sendable, Hashable {
        public let conformsTo: [String]
        public let extensions: [String]
    }

    public var id: String { label }
    public var primaryType: String { contentTypes[0] }

    /// Listed in Settings › Default editor for…. Not HTML: making an app
    /// the default for public.html makes macOS ask whether it should be
    /// the default web browser (seen on macOS 26), which an editor must
    /// never ask. HTML keeps its icon for a user who picks Owlink in Finder.
    public var inSettings: Bool { label != "HTML" }

    /// The content types Settings makes Owlink the default for: the claimed
    /// ones without abstract parents macOS asks about separately
    /// ("all Log File documents" for public.log).
    public var settingsTypes: [String] { contentTypes.filter { $0 != "public.log" } }

    /// A file extension of this type (for the Settings list and checks).
    public var sampleExtension: String {
        imported?.extensions.first ?? UTType(primaryType)?.preferredFilenameExtension ?? label.lowercased()
    }

    public init(label: String, icon: String, name: String, contentTypes: [String], imported: Imported? = nil,
                rank: Rank = .none) {
        self.label = label
        self.icon = icon
        self.name = name
        self.contentTypes = contentTypes
        self.imported = imported
        self.rank = rank
    }
}

public enum DocumentTypes {
    private static func imp(_ conforms: [String], _ exts: [String]) -> DocumentFileType.Imported {
        .init(conformsTo: conforms, extensions: exts)
    }

    /// The labelled types, in the Settings list's order. The Alternate ones
    /// hold 0.2.x's exact claims, so a type Owlink opens by itself shows
    /// its own icon (Finder draws the icon of the claim that won).
    public static let all: [DocumentFileType] = [
        .init(label: "TXT", icon: "doc-txt", name: "Plain Text", contentTypes: ["public.plain-text"], rank: .alternate),
        // Imported: macOS 15 and earlier have no Markdown type (26 does; then this is inactive).
        .init(label: "MD", icon: "doc-md", name: "Markdown", contentTypes: ["net.daringfireball.markdown"],
              imported: imp(["public.plain-text"], ["md", "markdown"]), rank: .alternate),
        .init(label: "JSON", icon: "doc-json", name: "JSON", contentTypes: ["public.json"], rank: .alternate),
        .init(label: "YAML", icon: "doc-yaml", name: "YAML", contentTypes: ["public.yaml"], rank: .alternate),
        .init(label: "SWIFT", icon: "doc-swift", name: "Swift Source", contentTypes: ["public.swift-source"]),
        .init(label: "PY", icon: "doc-py", name: "Python Script", contentTypes: ["public.python-script"]),
        .init(label: "JS", icon: "doc-js", name: "JavaScript", contentTypes: ["com.netscape.javascript-source"]),
        .init(label: "TS", icon: "doc-ts", name: "TypeScript", contentTypes: ["com.microsoft.typescript"],
              imported: imp(["public.script", "public.source-code"], ["tsx", "ts"])),
        .init(label: "SH", icon: "doc-sh", name: "Shell Script",
              contentTypes: ["public.shell-script", "public.zsh-script", "public.bash-script"]),
        .init(label: "LOG", icon: "doc-log", name: "Log File", contentTypes: ["com.apple.log", "public.log"]),
        .init(label: "CSV", icon: "doc-csv", name: "CSV", contentTypes: ["public.comma-separated-values-text"]),
        .init(label: "XML", icon: "doc-xml", name: "XML", contentTypes: ["public.xml"], rank: .alternate),
        .init(label: "HTML", icon: "doc-html", name: "HTML", contentTypes: ["public.html"], rank: .alternate),
        .init(label: "CSS", icon: "doc-css", name: "CSS", contentTypes: ["public.css"], rank: .alternate),
        .init(label: "TOML", icon: "doc-toml", name: "TOML", contentTypes: ["public.toml"], imported: imp(["public.text"], ["toml"])),
        .init(label: "INI", icon: "doc-ini", name: "INI Settings", contentTypes: ["com.microsoft.ini"], imported: imp(["public.text"], ["ini"])),
        .init(label: "SQL", icon: "doc-sql", name: "SQL", contentTypes: ["org.iso.sql"], imported: imp(["public.source-code"], ["sql"])),
        .init(label: "PS1", icon: "doc-ps1", name: "PowerShell Script", contentTypes: ["com.microsoft.powershell-script"],
              imported: imp(["public.script"], ["ps1", "psm1", "psd1"])),
    ]

    /// The rows of Settings › Default editor for….
    public static var settingsTypes: [DocumentFileType] { all.filter(\.inSettings) }

    /// Any other text: the unlabelled icon. At Alternate with the rest of
    /// 0.2.x's claims that no labelled Alternate row holds (public.log too:
    /// LOG is None, see Resources/document-types.txt), so together with
    /// those rows no default changes on update.
    public static let catchAll = DocumentFileType(label: "*", icon: "doc-text", name: "Text", contentTypes: [
        "public.text", "public.source-code", "public.script", "public.log", "public.data",
    ], rank: .alternate)

    /// Every row of Resources/document-types.txt, in order.
    public static var declared: [DocumentFileType] { all + [catchAll] }

    /// Parses Resources/document-types.txt (the format its header describes).
    public static func parse(_ text: String) -> [DocumentFileType] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            guard !l.isEmpty, !l.hasPrefix("#") else { return nil }
            let f = l.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count == 6, let rank = DocumentFileType.Rank(rawValue: f[5]) else { return nil }
            var imported: DocumentFileType.Imported?
            if f[4] != "-" {
                let parts = f[4].split(separator: ";", omittingEmptySubsequences: false).map(String.init)
                guard parts.count == 2 else { return nil }
                imported = .init(conformsTo: parts[0].split(separator: ",").map(String.init),
                                 extensions: parts[1].split(separator: ",").map(String.init))
            }
            return DocumentFileType(label: f[0], icon: f[1], name: f[2], contentTypes: f[3].split(separator: ",").map(String.init),
                                    imported: imported, rank: rank)
        }
    }
}

// MARK: - Settings › Default editor for…

/// What Launch Services says and does; the app passes NSWorkspace, tests a fake.
public protocol DefaultAppService: Sendable {
    /// The app that opens this content type now (nil: none).
    func defaultApp(forContentType id: String) -> URL?
    /// Makes `app` the default for the content type. macOS may ask the
    /// user first; throws when it refused or the user said no.
    func setDefaultApp(_ app: URL, forContentType id: String) async throws
}

/// The Settings list: one row per labelled type, with the app that opens
/// it now. Nothing here changes a default except `setOwlink`/`useOwlinkForAll`,
/// which only a click calls.
@MainActor
public final class DefaultEditorModel {
    public struct Row: Equatable, Sendable {
        public let type: DocumentFileType
        /// The app that opens the type now (nil: none).
        public let current: URL?
        /// Owlink opens it: the checkbox is on.
        public let isOwlink: Bool
        /// What the row shows after the type's name ("Xcode", "Owlink", "no app").
        public var currentName: String {
            guard let current else { return "no app" }
            return current.deletingPathExtension().lastPathComponent
        }
    }

    public let app: URL
    public let service: DefaultAppService
    public private(set) var rows: [Row] = []
    /// Where the app before Owlink is remembered (content type → app path), so
    /// unticking a box can give the type back to it.
    let defaults: UserDefaults
    static let previousKey = "defaultEditorPrevious"

    public init(app: URL, service: DefaultAppService, defaults: UserDefaults = .standard) {
        self.app = app
        self.service = service
        self.defaults = defaults
        reload()
    }

    func isOwlink(_ url: URL?) -> Bool {
        guard let url else { return false }
        if url.standardizedFileURL == app.standardizedFileURL { return true }
        // Another copy of Owlink (dist/ vs /Applications) counts: same bundle id.
        if let a = Bundle(url: url)?.bundleIdentifier, let b = Bundle(url: app)?.bundleIdentifier { return a == b }
        return false
    }

    /// Reads every type's current default again.
    public func reload() {
        rows = DocumentTypes.settingsTypes.map { t in
            let cur = service.defaultApp(forContentType: t.primaryType)
            return Row(type: t, current: cur, isOwlink: isOwlink(cur))
        }
    }

    var previous: [String: String] {
        get { defaults.dictionary(forKey: Self.previousKey) as? [String: String] ?? [:] }
        set { defaults.set(newValue, forKey: Self.previousKey) }
    }

    /// The app a type had before Owlink took it (if it still exists).
    public func previousApp(for type: DocumentFileType) -> URL? {
        guard let p = previous[type.primaryType], FileManager.default.fileExists(atPath: p) else { return nil }
        return URL(fileURLWithPath: p)
    }

    public enum Outcome: Equatable, Sendable {
        case done
        /// Unticked, but there is no earlier app to give the type back to.
        case noPreviousApp
        case failed(String)
    }

    /// The user ticked (`on`) or unticked a type's box. Ticking makes Owlink
    /// the default for all of the type's content types; unticking gives
    /// them back to the app that had them before, if Owlink remembers one.
    public func setOwlink(_ on: Bool, for type: DocumentFileType) async -> Outcome {
        defer { reload() }
        if on {
            var prev = previous
            for c in type.settingsTypes {
                let cur = service.defaultApp(forContentType: c)
                if let cur, !isOwlink(cur), prev[c] == nil { prev[c] = cur.path }
            }
            previous = prev
            do {
                // The first (shown) type decides; the related ones follow.
                try await service.setDefaultApp(app, forContentType: type.primaryType)
            } catch {
                return .failed(error.localizedDescription)
            }
            for c in type.settingsTypes.dropFirst() { try? await service.setDefaultApp(app, forContentType: c) }
            return .done
        }
        guard let back = previousApp(for: type) else { return .noPreviousApp }
        do {
            try await service.setDefaultApp(back, forContentType: type.primaryType)
        } catch {
            return .failed(error.localizedDescription)
        }
        var prev = previous
        for c in type.settingsTypes {
            if c != type.primaryType, let p = prev[c], FileManager.default.fileExists(atPath: p) {
                try? await service.setDefaultApp(URL(fileURLWithPath: p), forContentType: c)
            }
            prev[c] = nil
        }
        previous = prev
        return .done
    }

    /// "Use Owlink for all text files": every listed type, including the
    /// ones Owlink already opens only because nothing claims them better
    /// (an explicit choice is what gives Finder the labelled icon; macOS
    /// doesn't ask again for those). Stops at the first refusal (the user
    /// said no to macOS's prompt) and returns how many types it set.
    public func useOwlinkForAll() async -> (changed: Int, outcome: Outcome) {
        var n = 0
        for row in rows {
            let r = await setOwlink(true, for: row.type)
            if r != .done { return (n, r) }
            n += 1
        }
        return (n, .done)
    }
}
