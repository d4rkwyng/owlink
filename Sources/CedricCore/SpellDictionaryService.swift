import Foundation

/// The spell checker's dictionaries as Owlink uses them: what the
/// first-frame check's skip decision reads (SpellCheckCoverage), what Fix
/// Typos' Ignore All and Learn Word write, and the in-process notice of a
/// word learned or unlearned.
///
/// The app uses the system's (NSSpellChecker.shared, in CedricApp); the
/// dev checks (CEDRIC_CHECK) and the tests use `RecordingSpellDictionary`,
/// so what goes through this seam (Fix Typos' Learn Word and Ignore All,
/// the checks' own learns and ignores) never reaches the user's real
/// spelling dictionary. AppKit's own spelling actions don't go through
/// it: the native Ignore Spelling (`ignoreSpelling(_:)`, which the view
/// overrides only to clear the record before calling super), the context
/// menu's and the spelling panel's Learn and Ignore all write AppKit's
/// spell checker directly, so a check that invoked one of them would
/// reach the real one (none does).
public protocol SpellDictionaryService: AnyObject {
    func language() -> String
    var automaticallyIdentifiesLanguages: Bool { get }
    func ignoredWords(inSpellDocumentWithTag tag: Int) -> [String]?
    /// A round trip to the spell server, each.
    func hasLearnedWord(_ word: String) -> Bool
    func learnWord(_ word: String)
    func ignoreWord(_ word: String, inSpellDocumentWithTag tag: Int)
    /// Where, and under which names, a word learned or unlearned in this
    /// process is announced (on the thread that learned it).
    var learnedNotificationCenter: NotificationCenter { get }
    var learnedNotificationNames: [Notification.Name] { get }
    /// Checks only: the real spell checker doesn't know this dictionary's
    /// words, so the view drops the marks it made on them (`suppressesMark`)
    /// as the real one would never have made them. False for the system's.
    var suppressesMarks: Bool { get }
    func suppressesMark(_ word: String, inSpellDocumentWithTag tag: Int) -> Bool
}

public extension SpellDictionaryService {
    var suppressesMarks: Bool { false }
    func suppressesMark(_ word: String, inSpellDocumentWithTag tag: Int) -> Bool { false }

    /// The dictionary's state for the document `tag` (SpellDictionaryState):
    /// `learnedAmong`, the early check's marked words now learned.
    func state(forDocument tag: Int, learnedAmong words: [String] = []) -> SpellDictionaryState {
        SpellDictionaryState(language: language(), automaticByLanguage: automaticallyIdentifiesLanguages,
                             ignored: Set(ignoredWords(inSpellDocumentWithTag: tag) ?? []),
                             learned: Set(words.filter { hasLearnedWord($0) }))
    }
}

/// Which app is in front, as the learned-word rule sees it
/// (SpellCheckCoverage.asksLearned).
public enum SpellFrontApp {
    /// The lock screen's process: nobody types into any app behind it.
    public static let lockScreen = "com.apple.loginwindow"

    /// Owlink is the active app, or the lock screen is in front: the user
    /// can't be typing, nor learning a word, in any other app.
    /// `frontmostBundleID` is read only when Owlink isn't active.
    public static func onlyOwlinkInFront(isActive: Bool, frontmostBundleID: @autoclosure () -> String?) -> Bool {
        isActive || frontmostBundleID() == lockScreen
    }

    /// Owlink resigned active (`activated` nil) or an app was activated:
    /// true unless that app is Owlink (`ownPID`) or the lock screen, a word
    /// may be learned there.
    public static func mayLearnElsewhere(activated: (pid: Int32, bundleID: String?)?, ownPID: Int32) -> Bool {
        guard let activated else { return true }
        return activated.pid != ownPID && activated.bundleID != lockScreen
    }
}

/// Calls `learned` each time `dictionary` announces a word learned or
/// unlearned in this process, on the announcing thread; until released.
public final class SpellLearnedWatch {
    private let center: NotificationCenter
    private var tokens: [NSObjectProtocol] = []

    public init(_ dictionary: SpellDictionaryService, learned: @escaping @Sendable () -> Void) {
        center = dictionary.learnedNotificationCenter
        tokens = dictionary.learnedNotificationNames.map { center.addObserver(forName: $0, object: nil, queue: nil) { _ in learned() } }
    }

    deinit { tokens.forEach(center.removeObserver) }
}

public extension SpellCheckCoverage {
    /// The first-frame check is about to check `range` of the document
    /// `tag` for `types`.
    mutating func checked(_ range: NSRange, types: UInt64, dictionary: SpellDictionaryService, tag: Int, onlyOwlinkInFront: Bool,
                          spellingUIShown: Bool = false) {
        checked(range, types: types, dictionary: dictionary.state(forDocument: tag), onlyOwlinkInFront: onlyOwlinkInFront,
                spellingUIShown: spellingUIShown)
    }

    /// AppKit's pass asks to check `request` (NSTextView.checkText): true
    /// when the early check already did it (skip it). If some other app is
    /// in front now, or AppKit's spelling UI is up (`spellingUIShown`), the
    /// marked words are asked about. Nothing is asked when there is no record.
    mutating func takeAppKitPass(_ request: NSRange, types requestTypes: UInt64, hasOptions: Bool,
                                 onlyOwlinkInFront: Bool, spellingUIShown: Bool = false, dictionary: SpellDictionaryService, tag: Int) -> Bool {
        guard !isEmpty else { return false }
        if !onlyOwlinkInFront { anotherAppInFront() }
        if spellingUIShown { self.spellingUIShown() }
        return take(request, types: requestTypes, hasOptions: hasOptions,
                    dictionary: dictionary.state(forDocument: tag, learnedAmong: wordsToAskLearned))
    }
}

/// A spelling dictionary of its own, for the dev checks and the tests:
/// learning or ignoring a word here never reaches the user's real one.
/// Learning posts its own notice, as the system's spell checker does in
/// process; `learnElsewhere` stands for another app learning one, and
/// `learnSilently` for AppKit learning one in Owlink without its notice
/// (neither posts). Records what it was told and asked.
public final class RecordingSpellDictionary: SpellDictionaryService, @unchecked Sendable {
    public static let learnedName = Notification.Name("RecordingSpellDictionaryDidLearnWord")

    private let readLanguage: () -> String
    private let readAutomatic: () -> Bool
    public private(set) var learned: Set<String> = []
    public private(set) var ignored: [Int: Set<String>] = [:]
    /// Learn Word and Ignore All as they were called.
    public private(set) var learnCalls: [String] = []
    public private(set) var ignoreCalls: [String] = []
    /// Every hasLearnedWord question.
    public private(set) var asked: [String] = []
    public let learnedNotificationCenter = NotificationCenter()
    public var learnedNotificationNames: [Notification.Name] { [Self.learnedName] }

    /// `language` and `automatic`: read when asked (the checks pass the
    /// system's, which only reads them).
    public init(language: @escaping () -> String = { "en" }, automatic: @escaping () -> Bool = { true }) {
        readLanguage = language
        readAutomatic = automatic
    }

    public func language() -> String { readLanguage() }
    public var automaticallyIdentifiesLanguages: Bool { readAutomatic() }

    public func ignoredWords(inSpellDocumentWithTag tag: Int) -> [String]? {
        ignored[tag].map { $0.sorted() }
    }

    public func hasLearnedWord(_ word: String) -> Bool {
        asked.append(word)
        return learned.contains(word)
    }

    public func learnWord(_ word: String) {
        learnCalls.append(word)
        learned.insert(word)
        learnedNotificationCenter.post(name: Self.learnedName, object: self)
    }

    /// Another app learned `word`: nothing in this process hears of it.
    public func learnElsewhere(_ word: String) {
        learned.insert(word)
    }

    /// AppKit learned `word` in this process (the spelling panel's Learn)
    /// without posting the notice: nothing hears of it either.
    public func learnSilently(_ word: String) {
        learned.insert(word)
    }

    public func ignoreWord(_ word: String, inSpellDocumentWithTag tag: Int) {
        ignoreCalls.append(word)
        ignored[tag, default: []].insert(word)
    }

    public var suppressesMarks: Bool { true }

    public func suppressesMark(_ word: String, inSpellDocumentWithTag tag: Int) -> Bool {
        learned.contains(word) || ignored[tag]?.contains(word) == true
    }
}
