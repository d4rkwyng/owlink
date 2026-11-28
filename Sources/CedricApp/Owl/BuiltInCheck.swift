import AppKit
import CedricCore
import CedricAI

/// CEDRIC_BUILTIN_CHECK=/out/dir: the built-in engine's downloads in the
/// Settings › Cedric, in process, with real clicks. Use CEDRIC_MODELS_DIR=<temp>
/// so the real Application Support models are left alone. Downloads the
/// catalog model CEDRIC_BUILTIN_CHECK_MODEL (default: the 1.5B, the smallest)
/// for real from Hugging Face.
///
///   1. Cedric › Cedric AI Settings… (Settings › Cedric); pick "Built-in"; one
///      Model popup lists Automatic and every catalog model (snapshot 0-models).
///   2. Pick the model in the popup: it becomes the download target and
///      Automatic stays in effect. Click the one action button (Download),
///      confirm the bundled license; progress moves on the status line, Cancel
///      sits on the same row (snapshot 1-downloading).
///   3. Click Pause; the status says Paused, the partial file is on disk
///      (snapshot 2-paused).
///   4. Click Resume; it finishes, the SHA-256 checks, Automatic (still in
///      effect) picks it and the button says Delete (snapshot 3-installed).
///   5. Click Delete; the file is gone (snapshot 4-deleted).
@MainActor
enum BuiltInCheck {
    static var model: String { AICheck.env["CEDRIC_BUILTIN_CHECK_MODEL"] ?? "qwen2.5-coder-1.5b-instruct-q4_k_m" }

    static func run(_ app: AppDelegate, out: String) {
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(#selector(AppDelegate.showAISettings(_:)), to: app, from: nil)
        guard let sheet = SettingsWindowController.shared?.ai, let panel = SettingsWindowController.shared?.window else {
            AICheck.check(false, "Settings opened on the Cedric tab"); AICheck.finish(); return
        }
        let downloads = BuiltInDownloads.shared
        AICheck.log("models dir: \(downloads.store.directory.path)")
        guard let i = LocalAISettings.Backend.allCases.firstIndex(of: .builtIn) else { return }
        sheet.presetPopup.selectItem(at: i)
        NSApp.sendAction(sheet.presetPopup.action!, to: sheet.presetPopup.target, from: sheet.presetPopup)
        let view = sheet.modelsView
        let popup = sheet.modelPopup
        AICheck.check(!view.isHiddenOrHasHiddenAncestor && !view.controls.isHiddenOrHasHiddenAncestor, "Built-in shows the model chooser")
        let catalog = downloads.catalog?.models ?? []
        let listed = popup.itemArray.compactMap { $0.representedObject as? String }
        AICheck.check(catalog.count == 5 && listed == catalog.map(\.id), "the Model popup lists every catalog model (\(listed.count))")
        guard let m = downloads.catalog?.model(id: model),
              let item = popup.itemArray.firstIndex(where: { $0.representedObject as? String == model }) else {
            AICheck.check(false, "Model popup item for \(model)"); AICheck.finish(); return
        }
        let before = sheet.settings.model
        popup.selectItem(at: item)
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        AICheck.check(sheet.settings.model == before && sheet.builtInTarget == m.id && view.model == m,
                      "picking \(m.name) makes it the download target; the model in use stays \(before ?? "Automatic")")
        AICheck.check(downloads.state(m) == .notDownloaded && view.action.title == "Download", "\(m.name): Download")
        OwlCheck.after(0.3) {
            OwlCheck.snapshot(panel, "\(out)/0-models.png") {
                AICheck.press(view.action, "Download") { view.licenseConfirmationAlert != nil }
                AICheck.wait("licence confirmation", timeout: 10, { view.licenseConfirmationAlert != nil }) { shown in
                    AICheck.check(shown, "Download presents the bundled licence before starting")
                    guard let alert = view.licenseConfirmationAlert, let confirm = alert.buttons.first else {
                        AICheck.finish(); return
                    }
                    AICheck.press(confirm, "Confirm") { if case .downloading = downloads.state(m) { return true }; return false }
                    AICheck.wait("progress", timeout: 60, { (downloads.state(m).fraction ?? 0) > 0.05 }) { ok in
                        AICheck.check(ok && view.action.title == "Pause" && !view.progress.isHidden, "downloading: \(view.status.stringValue)")
                        AICheck.check(!view.secondary.isHidden && view.secondary.title == "Cancel" && view.secondary.superview === view.controls,
                                      "Cancel on the same row")
                        OwlCheck.snapshot(panel, "\(out)/1-downloading.png") {
                            AICheck.press(view.action, "Pause") { if case .paused = downloads.state(m) { return true }; return false }
                            AICheck.wait("paused", timeout: 10, { if case .paused = downloads.state(m) { return true }; return false }) { ok in
                                let part = downloads.store.partialBytes(m)
                                AICheck.check(ok && view.action.title == "Resume" && part > 0, "paused with \(part) bytes on disk: \(view.status.stringValue)")
                                OwlCheck.snapshot(panel, "\(out)/2-paused.png") { resume(sheet, panel, m, before: before, out: out) }
                            }
                        }
                    }
                }
            }
        }
    }

    static func resume(_ sheet: AISettingsSection, _ panel: NSWindow, _ m: BuiltInModel, before: String?, out: String) {
        let downloads = BuiltInDownloads.shared
        let view = sheet.modelsView
        let t0 = Date()
        AICheck.press(view.action, "Resume") {
            if case .downloading = downloads.state(m) { return true }
            return false
        }
        AICheck.check(view.licenseConfirmationAlert == nil, "Resume does not prompt for the licence")
        AICheck.wait("installed", timeout: 900, { downloads.state(m) == .installed }) { ok in
            AICheck.check(ok && downloads.store.isInstalled(m), String(format: "resumed, verified and installed in %.0f s", Date().timeIntervalSince(t0)))
            AICheck.check(sheet.settings.model == before, "the download didn't switch the model in use (\(sheet.settings.model ?? "Automatic"))")
            if before == nil {
                AICheck.check(sheet.modelPopup.itemArray.first?.title.contains(m.id) == true && sheet.modelPopup.indexOfSelectedItem == 0,
                              "Automatic picks it: \(sheet.modelPopup.itemArray.first?.title ?? "-")")
            }
            let installed = downloads.engine.installedModels.map(\.id)
            AICheck.check(installed == [m.id], "installed models: \(installed)")
            AICheck.check(view.model == m && view.action.title == "Delete" && view.status.stringValue.contains("verified"), "status: \(view.status.stringValue)")
            // Never press Delete on a model this check didn't download.
            guard view.model == m else { AICheck.finish(); return }
            OwlCheck.snapshot(panel, "\(out)/3-installed.png") {
                AICheck.press(view.action, "Delete") { downloads.state(m) == .notDownloaded }
                AICheck.wait("deleted", timeout: 10, { downloads.state(m) == .notDownloaded }) { ok in
                    AICheck.check(ok && !FileManager.default.fileExists(atPath: downloads.store.fileURL(for: m).path), "deleted from disk")
                    // Automatic now shows the default; pick the deleted model again to see its own button.
                    if let i = sheet.modelPopup.itemArray.firstIndex(where: { $0.representedObject as? String == m.id }) {
                        sheet.modelPopup.selectItem(at: i)
                        NSApp.sendAction(sheet.modelPopup.action!, to: sheet.modelPopup.target, from: sheet.modelPopup)
                    }
                    AICheck.check(view.model == m && sheet.builtInTarget == m.id && view.action.title == "Download"
                                  && view.status.stringValue.hasPrefix("Not downloaded"), "\(m.name): back to Download (\(view.status.stringValue))")
                    OwlCheck.snapshot(panel, "\(out)/4-deleted.png") { AICheck.finish() }
                }
            }
        }
    }
}
