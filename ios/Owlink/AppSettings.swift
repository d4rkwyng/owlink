import UIKit
import CedricCore

/// The iOS app's own settings (font size, theme, wrap, owl hints), in
/// UserDefaults. The theme uses the Mac's key and values. Editors listen
/// for `AppSettings.changed`.
enum AppSettings {
    static let changed = Notification.Name("OwlinkSettingsChanged")

    enum Key {
        static let fontSize = "ios.fontSize"
        /// Same key as the Mac: the editor's PostScript face, nil for SF Mono.
        static let fontName = "fontName"
        static let wrap = "ios.wrap"
        static let owlHints = "ios.owlHints"
        static let lineNumbers = "ios.lineNumbers"
        static let showInvisibles = MenuToggleSetting.showInvisibles.defaultsKey
        static let showContextBar = "showContextBar"
        static let owlPlacement = "ios.owlPlacement"
        static let owlManualPlacement = "ios.owlManualPlacement"
        /// Same keys as the Mac (Settings › Writing). This app has its own defaults.
        static let styleCheck = "styleCheck"
        static let styleCheckExtra = "styleCheckExtra"
        static let styleCheckExceptions = "styleCheckExceptions"
        static let readableWidthDefault = "readableWidthDefault"
        static let readableColumns = "readableColumns"
        /// Same keys as Settings › Writing on the Mac.
        static let useProseFont = "useProseFont"
        static let proseFontName = "proseFontName"
        static let proseFontSize = "proseFontSize"
        static let autoCloseBrackets = "autoCloseBrackets"
        static let tabWidth = "tabWidth"
        static let indentWithTabs = "indentWithTabs"
        static let focusUnit = "focusUnit"
        /// Same keys as the Mac (Settings, Edit › Spelling and Grammar). Unset means on.
        static let checkSpellingWhileTyping = "checkSpellingWhileTyping"
        static let checkGrammarInProse = "checkGrammarInProse"
        static let highlightOccurrences = "highlightOccurrences"
        static let saveAutomatically = "ios.saveAutomatically"
        static let openReadOnly = "ios.openReadOnly"
        /// Same key as the Mac (Settings › "Reopen files from last session").
        static let reopenFilesFromLastSession = "reopenFilesFromLastSession"
        /// The Mac's find bar does not remember its Regex box; the phone does.
        static let findRegex = "ios.findRegex"
        static let theme = EditorTheme.defaultsKey
    }

    static let defaults = UserDefaults.standard

    /// Cleared at launch by `-OwlinkResetSettings` (UI tests, debug runs).
    static let launchResetKeys = [Key.fontSize, Key.fontName, Key.wrap, Key.lineNumbers, Key.showInvisibles, Key.showContextBar, Key.owlHints, Key.theme,
                                  Key.saveAutomatically, Key.openReadOnly, Key.reopenFilesFromLastSession,
                                  Key.owlPlacement, Key.owlManualPlacement, Key.focusUnit,
                                  Key.checkSpellingWhileTyping, Key.checkGrammarInProse]

    /// 15 pt on large screens (an iPad, an unfolded iPhone Duo), 13 on
    /// phone-sized ones: by size class, not device idiom (the Duo is a
    /// "phone" either way). Without traits: the frontmost window's.
    static func defaultFontSize(for traits: UITraitCollection?) -> Double {
        guard let t = traits else { return UIDevice.current.userInterfaceIdiom == .pad ? 15 : 13 }
        return EditorDefaults.fontSize(regularWidth: t.horizontalSizeClass == .regular, regularHeight: t.verticalSizeClass == .regular)
    }

    @MainActor static var defaultFontSize: Double {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ?? UIApplication.shared.connectedScenes.first as? UIWindowScene
        return defaultFontSize(for: scene?.traitCollection)
    }

    /// The size the person chose, or nil (the default for the screen then).
    static var chosenFontSize: Double? {
        let v = defaults.double(forKey: Key.fontSize)
        return v == 0 ? nil : min(max(v, fontSizes.lowerBound), fontSizes.upperBound)
    }

    /// Back to the default for each screen (Actual Size).
    static func resetFontSize() {
        defaults.removeObject(forKey: Key.fontSize)
        post()
    }
    static let fontSizes: ClosedRange<Double> = 9...32

    @MainActor static var fontSize: Double {
        get { chosenFontSize ?? defaultFontSize }
        set { defaults.set(min(max(newValue, fontSizes.lowerBound), fontSizes.upperBound), forKey: Key.fontSize); post() }
    }

    static var wrap: Bool {
        get { defaults.object(forKey: Key.wrap) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.wrap); post() }
    }

    static var lineNumbers: Bool {
        get { defaults.object(forKey: Key.lineNumbers) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.lineNumbers); post() }
    }

    static var showInvisibles: Bool {
        get { defaults.object(forKey: Key.showInvisibles) as? Bool ?? MenuToggleSetting.showInvisibles.defaultValue }
        set { defaults.set(newValue, forKey: Key.showInvisibles); post() }
    }

    static var showContextBar: Bool {
        get { defaults.object(forKey: Key.showContextBar) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showContextBar); post() }
    }

    static var defaultIndentation: Indentation {
        get {
            let width = defaults.integer(forKey: Key.tabWidth)
            return Indentation(usesTabs: defaults.bool(forKey: Key.indentWithTabs), width: width > 0 ? width : 4)
        }
        set {
            let indentation = Indentation(usesTabs: newValue.usesTabs, width: newValue.width)
            defaults.set(indentation.width, forKey: Key.tabWidth)
            defaults.set(indentation.usesTabs, forKey: Key.indentWithTabs)
            post()
        }
    }

    /// Pair brackets and quotes while typing in code. On by default.
    static var autoCloseBrackets: Bool {
        get { defaults.object(forKey: Key.autoCloseBrackets) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoCloseBrackets); post() }
    }

    /// The system's spelling checker in Markdown and plain text (never code or data). On by default.
    static var checkSpellingWhileTyping: Bool {
        get { defaults.object(forKey: Key.checkSpellingWhileTyping) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.checkSpellingWhileTyping); post() }
    }

    /// The system's grammar checker in Markdown and plain text, where the OS
    /// has one for text views (iOS 27); stored either way. On by default.
    static var checkGrammarInProse: Bool {
        get { defaults.object(forKey: Key.checkGrammarInProse) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.checkGrammarInProse); post() }
    }

    static var focusUnit: FocusUnit {
        get { defaults.string(forKey: Key.focusUnit).flatMap(FocusUnit.init(rawValue:)) ?? .paragraph }
        set { defaults.set(newValue.rawValue, forKey: Key.focusUnit); post() }
    }

    static var highlightOccurrences: Bool {
        get { defaults.object(forKey: Key.highlightOccurrences) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.highlightOccurrences); post() }
    }

    /// The owl's offline hints (rules): on by default, like the Mac.
    static var owlHints: Bool {
        get { defaults.object(forKey: Key.owlHints) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.owlHints); post() }
    }

    /// Style Check (filler, redundancies, clichés). Off until turned on.
    static var styleCheck: Bool {
        get { defaults.bool(forKey: Key.styleCheck) }
        set { defaults.set(newValue, forKey: Key.styleCheck); post() }
    }

    /// Phrases to flag on top of the English list ("very, kind of").
    static var styleCheckExtra: [String] {
        get { defaults.stringArray(forKey: Key.styleCheckExtra) ?? [] }
        set { defaults.set(newValue, forKey: Key.styleCheckExtra); post() }
    }

    /// Phrases never flagged. "Ignore this word" appends here.
    static var styleCheckExceptions: [String] {
        get { defaults.stringArray(forKey: Key.styleCheckExceptions) ?? [] }
        set { defaults.set(newValue, forKey: Key.styleCheckExceptions); post() }
    }

    /// What the owl's rules get. Nil while Style Check is off.
    static var styleCheckSettings: StyleCheck.Settings? {
        styleCheck ? StyleCheck.Settings(language: "en", extra: styleCheckExtra, exceptions: styleCheckExceptions) : nil
    }

    /// The default for a tab that has not chosen. Off until turned on.
    static var readableWidthDefault: Bool {
        get { defaults.bool(forKey: Key.readableWidthDefault) }
        set { defaults.set(newValue, forKey: Key.readableWidthDefault); post() }
    }

    /// How many characters the column is wide (60–100, 72 if unset).
    static var readableColumns: Int {
        get {
            let v = defaults.integer(forKey: Key.readableColumns)
            return v > 0 ? ReadableWidth.clamp(v) : ReadableWidth.defaultColumns
        }
        set { defaults.set(ReadableWidth.clamp(newValue), forKey: Key.readableColumns); post() }
    }

    /// Settings › Writing › Use a prose font for Markdown and plain text.
    static var useProseFont: Bool {
        get { defaults.bool(forKey: Key.useProseFont) }
        set { defaults.set(newValue, forKey: Key.useProseFont); post() }
    }

    /// A PostScript face, ProseFont.systemSerif (New York), or nil for SF Pro.
    static var proseFontName: String? {
        get { defaults.string(forKey: Key.proseFontName) }
        set {
            if let newValue { defaults.set(newValue, forKey: Key.proseFontName) }
            else { defaults.removeObject(forKey: Key.proseFontName) }
            post()
        }
    }

    /// The prose face's size at 100% editor zoom.
    static var proseFontSize: Double {
        get {
            let size = defaults.double(forKey: Key.proseFontSize)
            return size > 0 ? ProseFont.clamp(size) : ProseFont.defaultSize
        }
        set { defaults.set(ProseFont.clamp(newValue), forKey: Key.proseFontSize); post() }
    }

    /// "very, kind of ,, actually" → ["very", "kind of", "actually"].
    static func phrases(_ s: String) -> [String] {
        var out: [String] = []
        for p in s.split(separator: ",").map({ StyleCheck.normalize(String($0)) }) where !p.isEmpty && !out.contains(p) {
            out.append(p)
        }
        return out
    }

    /// Save automatically (UIDocument's autosave): on by default. Off, the
    /// file changes only on Save; closing with changes asks.
    static var saveAutomatically: Bool {
        get { defaults.object(forKey: Key.saveAutomatically) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.saveAutomatically); post() }
    }

    /// Open documents read-only, with an Edit button: on by default on
    /// iPhone (a stray tap or key in a pocket edits nothing), off on iPad.
    static var openReadOnlyDefault: Bool { UIDevice.current.userInterfaceIdiom == .phone }

    /// Whether Find uses regular expressions ("Regex" in the find options).
    static var findRegex: Bool {
        get { defaults.bool(forKey: Key.findRegex) }
        set { defaults.set(newValue, forKey: Key.findRegex) }
    }

    static var openReadOnly: Bool {
        get { defaults.object(forKey: Key.openReadOnly) as? Bool ?? openReadOnlyDefault }
        set { defaults.set(newValue, forKey: Key.openReadOnly); post() }
    }

    /// Settings › "Reopen files from last session": the last open document
    /// opens again at launch. On unless Owlink's own preference says off,
    /// as on the Mac since 0.5.2 (ccdb2d8); a missing key reads as unset,
    /// not as off. Read with the Mac's `SessionReopenPolicy`, so a
    /// `-reopenFilesFromLastSession NO` launch argument (a string, which
    /// `as? Bool` read as unset) turns it off too.
    static var reopenFilesFromLastSession: Bool {
        get { reopenFilesFromLastSession(in: defaults) }
        set { defaults.set(newValue, forKey: Key.reopenFilesFromLastSession); post() }
    }

    static func reopenFilesFromLastSession(in defaults: UserDefaults) -> Bool {
        SessionReopenPolicy.shouldReopen(in: defaults)
    }

    /// The Settings toggle's write: stores `on`, then returns what launch
    /// will read (`reopenFilesFromLastSession(in:)`), which the toggle
    /// shows. A launch argument outranks the stored value, so under
    /// `-reopenFilesFromLastSession NO` the toggle stays off, as launch does.
    @discardableResult
    static func setReopenFilesFromLastSession(_ on: Bool, in defaults: UserDefaults) -> Bool {
        defaults.set(on, forKey: Key.reopenFilesFromLastSession)
        post()
        return reopenFilesFromLastSession(in: defaults)
    }

    static var theme: EditorTheme {
        get { defaults.string(forKey: Key.theme).flatMap(EditorTheme.init(rawValue:)) ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Key.theme); post() }
    }

    static func post() { NotificationCenter.default.post(name: changed, object: nil) }

    /// The editor's monospaced face (PostScript name), or nil for the
    /// system's monospaced font (SF Mono). A name that no longer loads stays
    /// stored; the editor falls back to SF Mono meanwhile.
    static var fontName: String? {
        get { defaults.string(forKey: Key.fontName).flatMap { $0.isEmpty ? nil : $0 } }
        set {
            if let newValue, !newValue.isEmpty { defaults.set(newValue, forKey: Key.fontName) }
            else { defaults.removeObject(forKey: Key.fontName) }
            post()
        }
    }

    private static var cachedEditorFont: (name: String?, size: CGFloat, font: UIFont)?

    /// The chosen editor face at `size`, else the monospaced system font.
    static func editorFont(ofSize size: CGFloat) -> UIFont {
        let name = fontName
        if let cached = cachedEditorFont, cached.name == name, cached.size == size { return cached.font }
        let font = name.flatMap { UIFont(name: $0, size: size) }
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: .regular)
        cachedEditorFont = (name, size, font)
        return font
    }

    @MainActor static func font(size: Double? = nil) -> UIFont {
        editorFont(ofSize: CGFloat(size ?? fontSize))
    }

    /// The editor's font for its own traits: unfolding a Duo goes from 13 to
    /// 15 pt unless the person chose a size.
    static func font(for traits: UITraitCollection) -> UIFont {
        editorFont(ofSize: CGFloat(chosenFontSize ?? defaultFontSize(for: traits)))
    }

    /// One regular face per installed monospaced family, sorted by family.
    private static let installedMonospacedFonts: [(title: String, name: String)] =
        UIFont.familyNames.sorted().compactMap { family in
            guard !family.hasPrefix("."), family != "SF Mono",
                  let name = regularFontName(forFamily: family), !name.hasPrefix("."),
                  let face = UIFont(name: name, size: 13),
                  face.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) else { return nil }
            return (family, name)
        }

    /// Settings › Font: "SF Mono (System)" (empty name) first, then one
    /// regular face per installed monospaced family, sorted by family, as
    /// the Mac's popup. A stored name not in that list still shows, last.
    static func editorFontChoices(current: String? = fontName) -> [(title: String, name: String)] {
        var out: [(title: String, name: String)] = [(String(localized: "SF Mono (System)"), "")] + installedMonospacedFonts
        if let current, !current.isEmpty, !out.contains(where: { $0.name == current }) {
            out.append((UIFont(name: current, size: 13)?.familyName ?? current, current))
        }
        return out
    }

    private static var cachedProseFont: (name: String?, size: CGFloat, font: UIFont)?

    static func proseFont(for traits: UITraitCollection) -> UIFont {
        let editorDefault = defaultFontSize(for: traits)
        let size = CGFloat(ProseFont.size(
            prose: proseFontSize,
            editor: chosenFontSize ?? editorDefault,
            editorDefault: editorDefault
        ))
        let name = proseFontName
        if let cached = cachedProseFont, cached.name == name, cached.size == size { return cached.font }

        let system = UIFont.systemFont(ofSize: size)
        let font: UIFont
        switch name {
        case nil:
            font = system
        case ProseFont.systemSerif?:
            font = system.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? system
        case let name?:
            font = UIFont(name: name, size: size) ?? system
        }
        cachedProseFont = (name, size, font)
        return font
    }

    static func font(for language: Language, traits: UITraitCollection) -> UIFont {
        ProseFont.applies(to: language, enabled: useProseFont) ? proseFont(for: traits) : font(for: traits)
    }

    /// The family's regular face, represented by its PostScript name.
    static func regularFontName(forFamily family: String) -> String? {
        let names = UIFont.fontNames(forFamilyName: family)
        return names.first { name in
            guard let font = UIFont(name: name, size: 13) else { return false }
            let traits = font.fontDescriptor.symbolicTraits
            return !traits.contains(.traitBold) && !traits.contains(.traitItalic)
        } ?? names.first
    }
}

extension UIColor {
    /// An sRGB colour from the core palettes' 0xRRGGBB.
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

private final class OwlinkBundleToken {}

extension Bundle {
    /// The bundle with Owlink's assets: the app, or the snapshot test
    /// bundle that compiles the same sources.
    static let owlink = Bundle(for: OwlinkBundleToken.self)
}
