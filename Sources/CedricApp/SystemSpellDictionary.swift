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
    /// learned or unlearned (any learnWord here, and the spelling panel's
    /// Learn when it posts one). Not in the SDK headers, and nothing relies
    /// on it alone: it only clears the record early. A word learned in the
    /// spelling panel or a menu without it is still caught, as the first
    /// pass then asks about the marked words (SpellingPanel.inUse, the
    /// menu-tracking observer: see watchSpellDictionary); spellopen
    /// checks both.
    var learnedNotificationNames: [Notification.Name] {
        [Notification.Name("NSSpellCheckerDidLearnWordNotification"), Notification.Name("NSSpellCheckerDidUnlearnWordNotification")]
    }
}
