import Foundation
import Testing
import UniformTypeIdentifiers
@testable import CedricCore

@Suite struct DocumentTypesTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    @Test func theListedTypes() {
        #expect(DocumentTypes.all.map(\.label) == ["TXT", "MD", "JSON", "YAML", "SWIFT", "PY", "JS", "TS", "SH", "LOG", "CSV",
                                                    "XML", "HTML", "CSS", "TOML", "INI", "SQL", "PS1"])
        let all = DocumentTypes.declared
        #expect(Set(all.map(\.label)).count == all.count)
        #expect(Set(all.map(\.icon)).count == all.count)
        let claims = DocumentTypes.all.flatMap(\.contentTypes)
        #expect(Set(claims).count == claims.count, "no content type is in two labelled rows")
    }

    /// Same defaults after the update: every content type is claimed by the
    /// same kind of row at the same rank as in 0.5.3, except that MD, JSON
    /// and YAML now hold their Alternate claim themselves (so Finder draws
    /// their icon), instead of the catch-all. TXT, XML, HTML and CSS stay
    /// None with their claim in the catch-all: as Alternate rows of their
    /// own, xml and css went from Safari to Owlink on a clean macOS 26 VM.
    @Test func ranksKeep0_5_3ButMdJsonYaml() {
        // 0.2.x's one Text entry, which 0.5.3 kept as the catch-all.
        let v02 = ["public.text", "public.plain-text", "public.source-code", "public.script", "public.json", "public.yaml",
                   "public.html", "public.xml", "public.css", "net.daringfireball.markdown", "public.log", "public.data"]
        let moved = ["net.daringfireball.markdown", "public.json", "public.yaml"]
        #expect(DocumentTypes.all.filter { $0.rank == .alternate }.map(\.label) == ["MD", "JSON", "YAML"])
        #expect(DocumentTypes.catchAll.rank == .alternate)
        #expect(DocumentTypes.catchAll.contentTypes == v02.filter { !moved.contains($0) })
        let alternate = DocumentTypes.declared.filter { $0.rank == .alternate }.flatMap(\.contentTypes)
        #expect(alternate.sorted() == v02.sorted(), "Alternate claims are 0.2.x's twelve, each once")

        // 0.5.3: labelled rows all None, catch-all Alternate. A claim is
        // (UTI, labelled or catch-all, rank).
        struct Claim: Hashable { let uti: String; let labelled: Bool; let rank: DocumentFileType.Rank }
        let labelled053 = ["public.plain-text", "net.daringfireball.markdown", "public.json", "public.yaml", "public.swift-source",
                           "public.python-script", "com.netscape.javascript-source", "com.microsoft.typescript",
                           "public.shell-script", "public.zsh-script", "public.bash-script", "com.apple.log", "public.log",
                           "public.comma-separated-values-text", "public.xml", "public.html", "public.css", "public.toml",
                           "com.microsoft.ini", "org.iso.sql", "com.microsoft.powershell-script"]
        var want = Set(labelled053.map { Claim(uti: $0, labelled: true, rank: .none) })
            .union(v02.map { Claim(uti: $0, labelled: false, rank: .alternate) })
        for u in moved {
            want.remove(Claim(uti: u, labelled: true, rank: .none))
            want.remove(Claim(uti: u, labelled: false, rank: .alternate))
            want.insert(Claim(uti: u, labelled: true, rank: .alternate))
        }
        let got = DocumentTypes.declared.flatMap { t in t.contentTypes.map { Claim(uti: $0, labelled: t.label != "*", rank: t.rank) } }
        #expect(got.count == Set(got).count, "no row claims a type twice")
        #expect(Set(got) == want)
    }

    @Test func infoPlistSourceMatchesTheModel() throws {
        let text = try String(contentsOf: Self.root.appendingPathComponent("Resources/document-types.txt"), encoding: .utf8)
        #expect(DocumentTypes.parse(text) == DocumentTypes.declared)
    }

    @Test func everyTypeHasItsIcon() {
        for t in DocumentTypes.declared {
            let p = Self.root.appendingPathComponent("Resources/DocIcons/\(t.icon).icns").path
            #expect(FileManager.default.fileExists(atPath: p), "\(p)")
        }
        let script = (try? String(contentsOf: Self.root.appendingPathComponent("tools/icon/doc_icons.py"), encoding: .utf8)) ?? ""
        for t in DocumentTypes.declared {
            #expect(script.contains("'\(t.icon)'"), "doc_icons.py makes \(t.icon)")
        }
    }

    @Test func systemTypesMapFromTheirExtensions() {
        // The types Owlink doesn't declare: macOS knows them, and a file's
        // extension resolves to them (or a subtype the claim covers).
        let ext = ["TXT": "txt", "JSON": "json", "YAML": "yaml", "SWIFT": "swift", "PY": "py", "JS": "js",
                   "SH": "sh", "LOG": "log", "CSV": "csv", "XML": "xml", "HTML": "html", "CSS": "css"]
        for t in DocumentTypes.all where t.imported == nil {
            #expect(UTType(t.primaryType) != nil, "\(t.primaryType) is declared by macOS")
            let e = ext[t.label]!
            let found = UTType(filenameExtension: e)
            #expect(found.map { f in t.contentTypes.contains { f.conforms(to: UTType($0)!) } } == true,
                    ".\(e) -> \(found?.identifier ?? "nil") is claimed by \(t.label)")
            #expect(found?.conforms(to: .text) == true, ".\(e) is text")
        }
        #expect(UTType(filenameExtension: "zsh").map { $0.conforms(to: UTType("public.shell-script")!) } == true)
    }

    @Test func settingsList() {
        #expect(DocumentTypes.settingsTypes.map(\.label) == DocumentTypes.all.map(\.label).filter { $0 != "HTML" })
        let log = DocumentTypes.all.first { $0.label == "LOG" }!
        #expect(log.settingsTypes == ["com.apple.log"])
        #expect(DocumentTypes.all.first { $0.label == "SH" }!.settingsTypes.count == 3)
        #expect(DocumentTypes.all.first { $0.label == "TS" }!.sampleExtension == "tsx", ".ts is a video type to macOS first")
    }

    @Test func importedDeclarations() {
        let imported = DocumentTypes.all.filter { $0.imported != nil }
        #expect(imported.map(\.label) == ["MD", "TS", "TOML", "INI", "SQL", "PS1"])
        for t in imported {
            let i = t.imported!
            #expect(!i.extensions.isEmpty && !i.conformsTo.isEmpty)
            #expect(i.conformsTo.allSatisfy { UTType($0) != nil }, "\(t.label) conforms to system types")
            #expect(i.conformsTo.allSatisfy { UTType($0)!.conforms(to: .text) }, "\(t.label) is declared as text")
            #expect(t.sampleExtension == i.extensions[0])
        }
        // .ts stays the system's video type by preference; the TypeScript
        // claim is a separate type.
        #expect(DocumentTypes.all.first { $0.label == "TS" }?.contentTypes == ["com.microsoft.typescript"])
    }
}

@MainActor
@Suite struct DefaultEditorModelTests {
    final class Fake: DefaultAppService, @unchecked Sendable {
        var map: [String: URL] = [:]
        var sets: [(String, URL)] = []
        var refuse: Set<String> = []
        func defaultApp(forContentType id: String) -> URL? { map[id] }
        func setDefaultApp(_ app: URL, forContentType id: String) async throws {
            if refuse.contains(id) { throw CocoaError(.userCancelled) }
            sets.append((id, app))
            map[id] = app
        }
    }

    // Real paths, so "the earlier app still exists" holds.
    let owlink = URL(fileURLWithPath: "/tmp/Owlink-test.app")
    let other = URL(fileURLWithPath: NSTemporaryDirectory())

    func make(_ f: Fake) -> (DefaultEditorModel, String) {
        let (d, n) = TestDefaults.make("cedric-default-")
        return (DefaultEditorModel(app: owlink, service: f, defaults: d), n)
    }

    @Test func readingChangesNothing() {
        let f = Fake()
        f.map["net.daringfireball.markdown"] = other
        f.map["public.json"] = owlink
        let (m, n) = make(f)
        defer { TestDefaults.remove(n) }
        #expect(f.sets.isEmpty)
        #expect(m.rows.count == DocumentTypes.settingsTypes.count)
        let md = m.rows.first { $0.type.label == "MD" }!
        #expect(!md.isOwlink && md.current == other)
        #expect(m.rows.first { $0.type.label == "JSON" }!.isOwlink)
        #expect(m.rows.first { $0.type.label == "TOML" }!.currentName == "no app")
    }

    @Test func tickAndUntick() async {
        let f = Fake()
        for c in ["public.shell-script", "public.zsh-script", "public.bash-script"] { f.map[c] = other }
        let (m, n) = make(f)
        defer { TestDefaults.remove(n) }
        let sh = DocumentTypes.all.first { $0.label == "SH" }!
        #expect(await m.setOwlink(true, for: sh) == .done)
        #expect(f.sets.map(\.0) == sh.contentTypes && f.sets.allSatisfy { $0.1 == owlink })
        #expect(m.rows.first { $0.type.label == "SH" }!.isOwlink)
        #expect(m.previousApp(for: sh) == other)
        f.sets.removeAll()
        #expect(await m.setOwlink(false, for: sh) == .done)
        #expect(f.sets.count == 3 && f.sets.allSatisfy { $0.1 == other })
        #expect(!m.rows.first { $0.type.label == "SH" }!.isOwlink)
        #expect(m.previousApp(for: sh) == nil, "forgotten once given back")
    }

    @Test func untickWithNoEarlierApp() async {
        let f = Fake()
        f.map["public.toml"] = owlink
        let (m, n) = make(f)
        defer { TestDefaults.remove(n) }
        let toml = DocumentTypes.all.first { $0.label == "TOML" }!
        #expect(await m.setOwlink(false, for: toml) == .noPreviousApp)
        #expect(f.sets.isEmpty)
    }

    @Test func refusalIsReported() async {
        let f = Fake()
        f.refuse = ["public.yaml"]
        let (m, n) = make(f)
        defer { TestDefaults.remove(n) }
        let (changed, outcome) = await m.useOwlinkForAll()
        #expect(changed == 3, "TXT, MD, JSON, then YAML was refused")
        if case .failed = outcome {} else { Issue.record("expected .failed, got \(outcome)") }
        #expect(f.map["public.yaml"] == nil)
        f.refuse = []
        let (rest, ok) = await m.useOwlinkForAll()
        #expect(ok == .done && rest == DocumentTypes.settingsTypes.count)
        #expect(m.rows.allSatisfy { $0.isOwlink })
        // Again: types Owlink already opens are set explicitly too (the
        // labelled icon needs an explicit choice); never HTML or public.log.
        f.sets.removeAll()
        let (again, _) = await m.useOwlinkForAll()
        #expect(again == DocumentTypes.settingsTypes.count)
        #expect(!f.sets.contains { $0.0 == "public.html" || $0.0 == "public.log" })
    }
}
