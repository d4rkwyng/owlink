import AppKit
import CedricCore

/// CEDRIC_CHECK=defaulteditor: Settings › Default editor for… against a
/// fake Launch Services (DefaultEditorPane.makeService), so the check never
/// changes this Mac's real default apps. Opening Settings changes nothing;
/// a tick makes Owlink the default for the type's content types; unticking
/// gives them back; "Use Owlink for All Text Files" takes the rest; a
/// refusal is reported, not hidden. Snapshot: defaulteditor-settings.png.
@MainActor
extension DevChecks {
    final class FakeDefaults: DefaultAppService, @unchecked Sendable {
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

    static func defaultEditorCheck(_ app: AppDelegate) {
        let fake = FakeDefaults()
        let other = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
        for t in DocumentTypes.all { for c in t.contentTypes { fake.map[c] = other } }
        fake.map["public.toml"] = nil
        DefaultEditorPane.makeService = { fake }
        let owlink = Bundle.main.bundleURL
        var pane: DefaultEditorPane? { SettingsWindowController.shared?.defaultEditor }
        func wait(_ cond: @escaping () -> Bool, _ then: @escaping () -> Void) {
            var n = 0
            @MainActor func poll() { if cond() || n > 50 { then() } else { n += 1; DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { poll() } } } }
            poll()
        }
        run([
            sync {
                SettingsWindowController.show(pane: .general)
                expect(pane != nil, "Settings has the Default editor for… pane")
                expect(fake.sets.isEmpty, "opening Settings changes no default")
                guard let p = pane else { return }
                expect(p.boxes.count == DocumentTypes.settingsTypes.count && p.boxes["HTML"] == nil, "one box per file type, none for HTML (macOS would ask about the web browser)", "\(p.boxes.count)")
                expect(p.boxes.values.allSatisfy { $0.state == .off }, "no box is ticked while other apps open the types")
                expect(p.currentLabels["MD"]?.stringValue == "TextEdit", "each row shows the current app", p.currentLabels["MD"]?.stringValue ?? "-")
                expect(p.currentLabels["TOML"]?.stringValue == "no app", "a type nothing opens says so", p.currentLabels["TOML"]?.stringValue ?? "-")
                expect(p.boxes["MD"]?.title == "Markdown (.md)", "rows name the type and its extension", p.boxes["MD"]?.title ?? "-")
            },
            snapshot("defaulteditor-settings.png", window: SettingsWindowController.shared?.window),
            { next in
                guard let box = pane?.boxes["SH"] else { next(); return }
                box.performClick(nil)
                wait({ fake.sets.count >= 3 }) {
                    expect(fake.sets.map(\.0) == ["public.shell-script", "public.zsh-script", "public.bash-script"],
                           "ticking Shell Script sets Owlink for its three content types", "\(fake.sets.map(\.0))")
                    expect(fake.sets.allSatisfy { $0.1 == owlink }, "…to this Owlink")
                    expect(pane?.boxes["SH"]?.state == .on && pane?.currentLabels["SH"]?.stringValue == "Owlink", "the box shows it")
                    next()
                }
            },
            { next in
                fake.sets.removeAll()
                pane?.boxes["SH"]?.performClick(nil)
                wait({ fake.sets.count >= 3 }) {
                    expect(fake.sets.allSatisfy { $0.1 == other }, "unticking gives the types back to the earlier app", "\(fake.sets)")
                    expect(pane?.boxes["SH"]?.state == .off, "…and the box is off")
                    next()
                }
            },
            { next in
                fake.sets.removeAll()
                fake.refuse = ["public.json"]
                pane?.allButton.performClick(nil)
                wait({ pane?.status.stringValue.isEmpty == false && pane?.allButton.isEnabled == true || fake.sets.count > 40 }) {
                    let s = pane?.status.stringValue ?? ""
                    expect(s.contains("didn't"), "a refusal (macOS prompt declined) stops Use for All and says so", s)
                    expect(!fake.sets.contains { $0.0 == "public.json" }, "the refused type isn't changed")
                    fake.refuse = []
                    pane?.status.stringValue = ""
                    pane?.allButton.performClick(nil)
                    wait({ pane?.status.stringValue.isEmpty == false }) {
                        expect(DocumentTypes.settingsTypes.allSatisfy { fake.map[$0.primaryType] == owlink }, "Use Owlink for All Text Files takes every type")
                        expect(pane?.boxes.values.allSatisfy { $0.state == .on } == true, "every box is ticked")
                        expect(!fake.sets.contains { $0.0 == "public.html" || $0.0 == "public.log" }, "never HTML (web browser) or the abstract public.log")
                        next()
                    }
                }
            },
            snapshot("defaulteditor-all.png", window: SettingsWindowController.shared?.window),
            sync { DefaultEditorPane.makeService = { WorkspaceDefaultApps() } },
        ])
    }
}
