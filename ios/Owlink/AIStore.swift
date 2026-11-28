import Foundation
import CedricAI

/// The AI settings iOS runs on: the saved settings, with automatic checks on
/// a server held off until its first-use notice is confirmed (as the Mac's
/// AIStore.load).
enum AIStore {
    static func load() -> LocalAISettings {
        LocalAISettings.load().applyingServerAutomaticAcknowledgement(
            UserDefaults.standard.bool(forKey: LocalAISettings.serverAutomaticChecksAcknowledgedKey))
    }
}

/// "Load model at launch" for the built-in model.
enum BuiltInPreload {
    /// "Load model at launch" (Settings › Built-in Models, off by default):
    /// the built-in model loads in the background at launch, under the
    /// watchdog and the iOS memory check (ModelMemoryGate), never on the
    /// main thread. Otherwise only a request the user makes loads it;
    /// opening a file never does. A device only (no simulator runtime).
    static func ifWanted(settings: LocalAISettings = AIStore.load(), engine: BuiltInEngine = BuiltInEngine()) {
        guard shouldPreload(settings: settings, available: engine.isAvailable) else { return }
        Task {
            guard let p = await engine.makeProvider(model: settings.model) as? any OwlPreloadingProvider else { return }
            try? await p.preload()
        }
    }

    static func shouldPreload(settings: LocalAISettings, available: Bool) -> Bool {
        settings.enabled && settings.backend == .builtIn && settings.loadModelAtLaunch && available
    }
}
