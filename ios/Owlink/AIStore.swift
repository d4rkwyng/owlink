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
