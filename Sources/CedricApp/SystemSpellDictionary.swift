import AppKit
import CedricCore

/// The user's spelling dictionary: NSSpellChecker.shared
/// (SpellDictionaryService). Only the app's own actions write it (Fix
/// Typos' Learn Word and Ignore All); the dev checks and tests use
/// RecordingSpellDictionary instead.
final class SystemSpellDictionary: SpellDictionaryService {
    private var checker: NSSpellChecker { NSSpellChecker.shared }

    func language() -> String { checker.language() }
    var automaticallyIdentifiesLanguages: Bool { checker.automaticallyIdentifiesLanguages }
    func ignoredWords(inSpellDocumentWithTag tag: Int) -> [String]? { checker.ignoredWords(inSpellDocumentWithTag: tag) }
    func hasLearnedWord(_ word: String) -> Bool { checker.hasLearnedWord(word) }
    func learnWord(_ word: String) { checker.learnWord(word) }
    func ignoreWord(_ word: String, inSpellDocumentWithTag tag: Int) { checker.ignoreWord(word, inSpellDocumentWithTag: tag) }

    var learnedNotificationCenter: NotificationCenter { .default }
    /// What AppKit's spell checker posts in this process when a word is
    /// learned or unlearned (the spelling panel's Learn, any learnWord
    /// here). Not in the SDK headers; the SpellCheckCoverage tests and
    /// spellopen show what depends on it (a word learned here while
    /// Owlink stays in front would keep its underline until the next pass).
    var learnedNotificationNames: [Notification.Name] {
        [Notification.Name("NSSpellCheckerDidLearnWordNotification"), Notification.Name("NSSpellCheckerDidUnlearnWordNotification")]
    }
}
