import AppKit
import CedricCore

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
}

extension Notification.Name {
    /// The theme, font size or a view option changed: every editor restyles.
    static let cedricAppearanceChanged = Notification.Name("CedricAppearanceChanged")
    /// The owl was switched on or off, or its hint source changed.
    static let cedricOwlSettingsChanged = Notification.Name("CedricOwlSettingsChanged")
    /// View › Context Bar was switched on or off.
    static let cedricContextBarChanged = Notification.Name("CedricContextBarChanged")
    static let cedricFocusUnitChanged = Notification.Name("CedricFocusUnitChanged")
    /// A setting nothing restyles for changed (auto-close, quit on last
    /// close): the Settings window shows it.
    static let cedricSettingsChanged = Notification.Name("CedricSettingsChanged")
}

/// App-wide view settings: theme, font size, wrap, invisibles, line
/// numbers. Saved in UserDefaults; `CEDRIC_THEME` overrides the theme for
/// one run (screenshots) without saving it.
@MainActor
final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard
    /// CEDRIC_THEME, or set by the typing check: used for this run, not saved.
    var themeOverride: EditorTheme?

    static let defaultFontSize: CGFloat = 13

    private init() {
        themeOverride = DevEnvironment.values["CEDRIC_THEME"].flatMap(EditorTheme.init(rawValue:))
    }

    var theme: EditorTheme {
        get { themeOverride ?? defaults.string(forKey: EditorTheme.defaultsKey).flatMap(EditorTheme.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: EditorTheme.defaultsKey); changed() }
    }

    /// Set by a check: the font size for this run, not saved (as
    /// `themeOverride`). Nil: the saved size.
    var fontSizeOverride: CGFloat? {
        didSet { if fontSizeOverride != oldValue { changed() } }
    }

    var fontSize: CGFloat {
        get {
            if let fontSizeOverride { return fontSizeOverride }
            let v = defaults.double(forKey: "fontSize"); return v > 0 ? v : Self.defaultFontSize
        }
        set { defaults.set(min(72, max(6, newValue)), forKey: "fontSize"); changed() }
    }

    var wrapLines: Bool {
        get { defaults.object(forKey: "wrapLines") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "wrapLines"); changed() }
    }

    /// Settings › Writing › Readable Width: the default for a tab that has
    /// not chosen for itself. Off (unchecked). An explicit per-tab choice
    /// is kept (ReadableWidthView.swift).
    var readableWidthDefault: Bool {
        get { defaults.bool(forKey: "readableWidthDefault") }
        set { defaults.set(newValue, forKey: "readableWidthDefault"); changed() }
    }

    /// Settings › Readable width: View › Readable Width's column, in
    /// characters (60–100, 72 by default; ReadableWidthView.swift).
    var readableColumns: Int {
        get { let v = defaults.integer(forKey: "readableColumns"); return v > 0 ? ReadableWidth.clamp(v) : ReadableWidth.defaultColumns }
        set { defaults.set(ReadableWidth.clamp(newValue), forKey: "readableColumns"); changed() }
    }

    /// CEDRIC_INVISIBLES=1: on for this run, not saved.
    let invisiblesOverride = DevEnvironment.values["CEDRIC_INVISIBLES"] == "1" ? true : nil as Bool?

    var showInvisibles: Bool {
        get { invisiblesOverride ?? defaults.bool(forKey: "showInvisibles") }
        set { defaults.set(newValue, forKey: "showInvisibles"); changed() }
    }

    var showLineNumbers: Bool {
        get { defaults.object(forKey: "showLineNumbers") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showLineNumbers"); changed() }
    }

    /// CEDRIC_OWL=1: show the owl for this run, not saved.
    var owlOverride = DevEnvironment.values["CEDRIC_OWL"].map { $0 == "1" }

    /// "Show Cedric the owl": off by default.
    var showOwl: Bool {
        get { owlOverride ?? defaults.bool(forKey: "showOwl") }
        set { defaults.set(newValue, forKey: "showOwl"); NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil) }
    }

    /// CEDRIC_CONTEXT_BAR=0/1 for one run; the checks (no session saving)
    /// switch it here without saving.
    var contextBarOverride = DevEnvironment.values["CEDRIC_CONTEXT_BAR"].map { $0 == "1" }
        ?? (DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] == "1" ? false : nil)

    /// View › Show Context Bar: on by default (UX review #3; the bar only
    /// exists for Markdown, ContextBar.swift). Once the user picks Show or
    /// Hide, that choice is kept.
    static let contextBarDefault = true

    var showContextBar: Bool {
        get { contextBarOverride ?? (defaults.object(forKey: "showContextBar") as? Bool ?? Self.contextBarDefault) }
        set {
            if contextBarOverride != nil { contextBarOverride = newValue } else { defaults.set(newValue, forKey: "showContextBar") }
            NotificationCenter.default.post(name: .cedricContextBarChanged, object: nil)
        }
    }

    /// The checks (no session saving) switch it here without saving.
    var focusUnitOverride: FocusUnit? = DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] == "1" ? .paragraph : nil

    /// View › Writing Mode › Focus on Paragraph / Sentence (WritingMode.swift).
    var focusUnit: FocusUnit {
        get { focusUnitOverride ?? defaults.string(forKey: "focusUnit").flatMap(FocusUnit.init(rawValue:)) ?? .paragraph }
        set {
            if focusUnitOverride != nil { focusUnitOverride = newValue } else { defaults.set(newValue.rawValue, forKey: "focusUnit") }
            NotificationCenter.default.post(name: .cedricFocusUnitChanged, object: nil)
        }
    }

    /// View › Check Spelling While Typing: on by default.
    var checkSpellingWhileTyping: Bool {
        get { defaults.object(forKey: "checkSpellingWhileTyping") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkSpellingWhileTyping"); changed() }
    }

    /// Settings › "Check grammar in prose" (and Edit › Spelling and
    /// Grammar › Check Grammar in Prose): on by default. Only Plain Text
    /// and Markdown that reads as sentences is checked (Grammar.swift).
    var checkGrammar: Bool {
        get { defaults.object(forKey: "checkGrammarInProse") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkGrammarInProse"); changed() }
    }

    /// Settings › "Ask Cedric": the owl's chat panel and its tools, and
    /// Check Grammar with Cedric. Until the user sets it, on exactly when a
    /// local engine is ready (`AskCedricEngine`): Apple Intelligence, a
    /// downloaded built-in model, or a server set up and turned on.
    /// CEDRIC_OWL_CHAT=0/1 for one run.
    var owlChat: Bool {
        get {
            if let v = DevEnvironment.values["CEDRIC_OWL_CHAT"] { return v == "1" }
            if let v = defaults.object(forKey: "owlChat") as? Bool { return v }
            return AskCedricEngine.isAvailable
        }
        set { defaults.set(newValue, forKey: "owlChat"); changed() }
    }

    /// Settings › "Style tips in code": Cedric's style rules for code run
    /// too. Off by default; his correctness rules (it breaks, or does the
    /// wrong thing) always run.
    var owlStyleTips: Bool {
        get { defaults.bool(forKey: "owlStyleTips") }
        set { defaults.set(newValue, forKey: "owlStyleTips"); changed() }
    }

    /// Settings › Style Check (0.4.0): filler words, redundancies and
    /// clichés in Markdown and Plain Text prose. Off by default.
    /// CEDRIC_STYLE_CHECK=1/0 overrides it (checks, perf runs).
    var styleCheck: Bool {
        get {
            if let v = DevEnvironment.values["CEDRIC_STYLE_CHECK"] { return v == "1" }
            return defaults.bool(forKey: "styleCheck")
        }
        set { defaults.set(newValue, forKey: "styleCheck"); changed() }
    }

    /// Style Check's own phrases to flag, and the ones never flagged
    /// ("Ignore this word" adds there).
    var styleCheckExtra: [String] {
        get { defaults.stringArray(forKey: "styleCheckExtra") ?? [] }
        set { defaults.set(newValue, forKey: "styleCheckExtra"); changed() }
    }
    var styleCheckExceptions: [String] {
        get { defaults.stringArray(forKey: "styleCheckExceptions") ?? [] }
        set { defaults.set(newValue, forKey: "styleCheckExceptions"); changed() }
    }

    /// What the owl's rules get (`OwlDocumentFacts.styleCheck`): nil when off.
    var styleCheckSettings: StyleCheck.Settings? {
        styleCheck ? StyleCheck.Settings(language: "en", extra: styleCheckExtra, exceptions: styleCheckExceptions) : nil
    }

    /// The user turned Ask Cedric off themselves (the owl then doesn't
    /// offer to set it up).
    var owlChatTurnedOff: Bool {
        DevEnvironment.values["CEDRIC_OWL_CHAT"] == "0" || defaults.object(forKey: "owlChat") as? Bool == false
    }

    /// View › Highlight Occurrences: other occurrences of the selection or
    /// the word under the caret are tinted on screen. On by default.
    var highlightOccurrences: Bool {
        get { defaults.object(forKey: "highlightOccurrences") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "highlightOccurrences"); changed() }
    }

    /// "Quit when the last window closes": closing the last document
    /// window (text, PDF, image or Office tab) quits the app. When Reopen
    /// files from last session is on, those tabs come back next launch; when
    /// it is off, they go to Reopen Closed Tab. On by default.
    var quitWhenLastWindowCloses: Bool {
        // bool(forKey:): a `-quitWhenLastWindowCloses NO` argument is a string.
        get { defaults.object(forKey: "quitWhenLastWindowCloses") == nil || defaults.bool(forKey: "quitWhenLastWindowCloses") }
        set { defaults.set(newValue, forKey: "quitWhenLastWindowCloses"); NotificationCenter.default.post(name: .cedricSettingsChanged, object: nil) }
    }

    /// Settings › "Reopen files from last session". On until the user turns
    /// it off here (SessionReopenPolicy: not macOS's global
    /// NSQuitAlwaysKeepsWindows, and a `-reopenFilesFromLastSession NO`
    /// launch argument counts). Off or on, unsaved text reopens.
    var reopenFilesFromLastSession: Bool {
        get { SessionReopenPolicy.shouldReopen(in: defaults) }
        set { defaults.set(newValue, forKey: SessionReopenPolicy.key); changed() }
    }

    /// Settings › "Show git changes in the gutter": change bars against
    /// the last commit for files in a git repository. On by default.
    var showGitChanges: Bool {
        get { defaults.object(forKey: "showGitChanges") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showGitChanges"); changed() }
    }

    /// Edit › Auto-Close Brackets and Quotes (code only, not prose). On by default.
    var autoCloseBrackets: Bool {
        get { defaults.object(forKey: "autoCloseBrackets") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoCloseBrackets"); NotificationCenter.default.post(name: .cedricSettingsChanged, object: nil) }
    }

    /// A menu toggle by name: the same property its menu item flips
    /// (Settings › Editor and Writing show them as checkboxes).
    subscript(toggle toggle: MenuToggleSetting) -> Bool {
        get {
            switch toggle {
            case .wrapLines: return wrapLines
            case .showInvisibles: return showInvisibles
            case .showLineNumbers: return showLineNumbers
            case .highlightOccurrences: return highlightOccurrences
            case .autoCloseBrackets: return autoCloseBrackets
            case .checkSpellingWhileTyping: return checkSpellingWhileTyping
            case .checkGrammar: return checkGrammar
            }
        }
        set {
            switch toggle {
            case .wrapLines: wrapLines = newValue
            case .showInvisibles: showInvisibles = newValue
            case .showLineNumbers: showLineNumbers = newValue
            case .highlightOccurrences: highlightOccurrences = newValue
            case .autoCloseBrackets: autoCloseBrackets = newValue
            case .checkSpellingWhileTyping: checkSpellingWhileTyping = newValue
            case .checkGrammar: checkGrammar = newValue
            }
        }
    }

    /// The checks move the owl without saving where he is.
    var owlPlacementInMemory: OwlPlacement?
    var owlPlacementSaves = DevEnvironment.values["CEDRIC_NO_SESSION_SAVE"] != "1"

    /// Where the owl sits over the editor (shared by every tab), as a
    /// corner plus an inset, so it survives window resizes.
    var owlPlacement: OwlPlacement {
        get {
            if !owlPlacementSaves { return owlPlacementInMemory ?? .default }
            guard let data = defaults.data(forKey: "owlPlacement"),
                  let p = try? JSONDecoder().decode(OwlPlacement.self, from: data) else { return .default }
            return p
        }
        set {
            if !owlPlacementSaves { owlPlacementInMemory = newValue; return }
            if let data = try? JSONEncoder().encode(newValue) { defaults.set(data, forKey: "owlPlacement") }
        }
    }

    /// CEDRIC_OWL_SOURCE=rulesAndAI: the hint source for this run, not saved.
    var owlSourceOverride = DevEnvironment.values["CEDRIC_OWL_SOURCE"].flatMap(OwlHintSource.init(rawValue:))

    /// "Hint source": Rules, or Rules + AI (only once an AI provider registers).
    var owlHintSource: OwlHintSource {
        get { owlSourceOverride ?? defaults.string(forKey: "owlHintSource").flatMap(OwlHintSource.init(rawValue:)) ?? .rules }
        set {
            if owlSourceOverride != nil { owlSourceOverride = newValue } else { defaults.set(newValue.rawValue, forKey: "owlHintSource") }
            NotificationCenter.default.post(name: .cedricOwlSettingsChanged, object: nil)
        }
    }

    /// Settings › Editor: how new and undetected documents indent.
    var defaultIndentation: Indentation {
        get {
            let w = defaults.integer(forKey: "tabWidth")
            return Indentation(usesTabs: defaults.bool(forKey: "indentWithTabs"), width: w > 0 ? w : 4)
        }
        set {
            defaults.set(newValue.width, forKey: "tabWidth")
            defaults.set(newValue.usesTabs, forKey: "indentWithTabs")
            changed()
        }
    }

    /// Settings › Font: a font's PostScript name, or nil for the system's
    /// monospaced font (SF Mono).
    var fontName: String? {
        get { defaults.string(forKey: "fontName") }
        set {
            if let newValue { defaults.set(newValue, forKey: "fontName") } else { defaults.removeObject(forKey: "fontName") }
            changed()
        }
    }

    private var cachedFont: (name: String?, size: CGFloat, font: NSFont)?

    /// The editor's font (asked for on every selection change: cached).
    var font: NSFont {
        let name = fontName, size = fontSize
        if let c = cachedFont, c.name == name, c.size == size { return c.font }
        let f = name.flatMap { NSFont(name: $0, size: size) } ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        cachedFont = (name, size, f)
        return f
    }

    /// Settings › Writing › "Use a prose font for Markdown and plain text"
    /// (0.4.1): off by default, so nothing changes until it is turned on.
    var useProseFont: Bool {
        get { useProseFontOverride ?? defaults.bool(forKey: "useProseFont") }
        set {
            // The override's own didSet posts the change.
            if useProseFontOverride != nil { useProseFontOverride = newValue; return }
            defaults.set(newValue, forKey: "useProseFont")
            changed()
        }
    }

    /// Set by a check: the prose font on or off for this run, not saved
    /// (as `fontSizeOverride`). Nil: the saved switch.
    var useProseFontOverride: Bool? {
        didSet { if useProseFontOverride != oldValue { changed() } }
    }

    /// Set by a check: a prose font for this run, not saved (as
    /// `fontSizeOverride`). Nil: the saved prose font.
    var proseFontNameOverride: String? {
        didSet { if proseFontNameOverride != oldValue { changed() } }
    }

    /// The prose font: a font's PostScript name, `ProseFont.systemSerif`
    /// (New York), or nil for the system font (SF Pro).
    var proseFontName: String? {
        get { proseFontNameOverride ?? defaults.string(forKey: "proseFontName") }
        set {
            // The override's own didSet posts the change (nil there ends
            // the override: back to the saved font).
            if proseFontNameOverride != nil { proseFontNameOverride = newValue; return }
            if let newValue { defaults.set(newValue, forKey: "proseFontName") } else { defaults.removeObject(forKey: "proseFontName") }
            changed()
        }
    }

    /// The prose font's size at 100% zoom (ProseFont.defaultSize, 15 pt).
    var proseFontSize: CGFloat {
        get { let v = defaults.double(forKey: "proseFontSize"); return v > 0 ? v : ProseFont.defaultSize }
        set { defaults.set(ProseFont.clamp(newValue), forKey: "proseFontSize"); changed() }
    }

    private var cachedProseFont: (name: String?, size: CGFloat, font: NSFont)?

    /// The prose font at the current zoom (cached like `font`).
    var proseFont: NSFont {
        let name = proseFontName
        let size = CGFloat(ProseFont.size(prose: proseFontSize, editor: fontSize, editorDefault: Self.defaultFontSize))
        if let c = cachedProseFont, c.name == name, c.size == size { return c.font }
        let system = NSFont.systemFont(ofSize: size)
        let f: NSFont
        switch name {
        case nil: f = system
        case ProseFont.systemSerif?:
            f = system.fontDescriptor.withDesign(.serif).flatMap { NSFont(descriptor: $0, size: size) } ?? system
        case let n?: f = NSFont(name: n, size: size) ?? system
        }
        cachedProseFont = (name, size, f)
        return f
    }

    /// The font for a tab in `language`: the prose font for Markdown and
    /// plain text when it is on, else the (monospaced) editor font.
    func font(for language: Language) -> NSFont {
        ProseFont.applies(to: language, enabled: useProseFont) ? proseFont : font
    }

    /// The palette for a view, resolving System against its appearance.
    func palette(for appearance: NSAppearance?) -> EditorPalette {
        let dark = (appearance ?? NSApp.effectiveAppearance).bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return theme.palette(systemIsDark: dark)
    }

    /// The window appearance a theme forces (nil: follow the system).
    var windowAppearance: NSAppearance? {
        switch theme {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark, .tankard, .dracula, .cedricNight: return NSAppearance(named: .darkAqua)
        case .cedric: return NSAppearance(named: .aqua)
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .cedricAppearanceChanged, object: nil)
    }
}
