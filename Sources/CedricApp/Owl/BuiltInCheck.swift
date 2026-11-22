import AppKit
import CedricCore
import CedricAI

/// CEDRIC_BUILTIN_CHECK=/out/dir: the built-in engine's downloads in the
/// Settings › Cedric, in process, with real clicks. Use CEDRIC_MODELS_DIR=<temp>
/// so the real Application Support models are left alone. Downloads the
/// catalog model CEDRIC_BUILTIN_CHECK_MODEL (default: the 1.5B, the smallest)
/// for real from Hugging Face.
///
///   1. Cedric › Cedric AI Settings… (Settings › Cedric); pick "Built-in"; the catalog rows show
///      (snapshot 0-models).
///   2. Click Download, confirm the bundled licence; progress moves (snapshot 1-downloading).
///   3. Click Pause; the row says Paused, the partial file is on disk
///      (snapshot 2-paused).
///   4. Click Resume; it finishes, the SHA-256 checks, the row says
///      Downloaded and the Model menu offers it (snapshot 3-installed).
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
        AICheck.check(!view.isHiddenOrHasHiddenAncestor, "Built-in shows the model list")
        AICheck.check(view.rows.count == (downloads.catalog?.models.count ?? -1) && view.rows.count == 5, "one row per catalog model (\(view.rows.count))")
        guard let row = view.row(model) else { AICheck.check(false, "row for \(model)"); AICheck.finish(); return }
        let m = row.model
        AICheck.check(downloads.state(m) == .notDownloaded && row.action.title == "Download", "\(m.name): Download")
        OwlCheck.after(0.3) {
            OwlCheck.snapshot(panel, "\(out)/0-models.png") {
                AICheck.press(row.action, "Download") { view.licenseConfirmationAlert != nil }
                AICheck.wait("licence confirmation", timeout: 10, { view.licenseConfirmationAlert != nil }) { shown in
                    AICheck.check(shown, "Download presents the bundled licence before starting")
                    guard let alert = view.licenseConfirmationAlert, let confirm = alert.buttons.first else {
                        AICheck.finish(); return
                    }
                    AICheck.press(confirm, "Confirm") { if case .downloading = downloads.state(m) { return true }; return false }
                    AICheck.wait("progress", timeout: 60, { (downloads.state(m).fraction ?? 0) > 0.05 }) { ok in
                        AICheck.check(ok && row.action.title == "Pause" && !row.progress.isHidden, "downloading: \(row.status.stringValue)")
                        OwlCheck.snapshot(panel, "\(out)/1-downloading.png") {
                            AICheck.press(row.action, "Pause") { if case .paused = downloads.state(m) { return true }; return false }
                            AICheck.wait("paused", timeout: 10, { if case .paused = downloads.state(m) { return true }; return false }) { ok in
                                let part = downloads.store.partialBytes(m)
                                AICheck.check(ok && row.action.title == "Resume" && part > 0, "paused with \(part) bytes on disk: \(row.status.stringValue)")
                                OwlCheck.snapshot(panel, "\(out)/2-paused.png") { resume(sheet, panel, row, out: out) }
                            }
                        }
                    }
                }
            }
        }
    }

    static func resume(_ sheet: AISettingsSection, _ panel: NSWindow, _ row: BuiltInModelsView.Row, out: String) {
        let downloads = BuiltInDownloads.shared
        let m = row.model
        let t0 = Date()
        AICheck.press(row.action, "Resume") {
            if case .downloading = downloads.state(m) { return true }
            return false
        }
        AICheck.check(SettingsWindowController.shared?.ai?.modelsView.licenseConfirmationAlert == nil, "Resume does not prompt for the licence")
        AICheck.wait("installed", timeout: 900, { downloads.state(m) == .installed }) { ok in
            AICheck.check(ok && downloads.store.isInstalled(m), String(format: "resumed, verified and installed in %.0f s", Date().timeIntervalSince(t0)))
            AICheck.check(row.action.title == "Delete" && row.status.stringValue.contains("verified"), "row: \(row.status.stringValue)")
            let offered = sheet.modelPopup.itemArray.compactMap { $0.representedObject as? String }
            AICheck.check(offered == [m.id], "the Model menu offers the download (\(offered))")
            AICheck.check(sheet.modelPopup.itemArray.first?.title.contains(m.id) == true, "Automatic picks it: \(sheet.modelPopup.itemArray.first?.title ?? "-")")
            OwlCheck.snapshot(panel, "\(out)/3-installed.png") {
                AICheck.press(row.action, "Delete") { downloads.state(m) == .notDownloaded }
                AICheck.wait("deleted", timeout: 10, { downloads.state(m) == .notDownloaded }) { ok in
                    AICheck.check(ok && !FileManager.default.fileExists(atPath: downloads.store.fileURL(for: m).path), "deleted from disk")
                    AICheck.check(row.action.title == "Download", "row back to Download")
                    OwlCheck.snapshot(panel, "\(out)/4-deleted.png") { AICheck.finish() }
                }
            }
        }
    }
}
