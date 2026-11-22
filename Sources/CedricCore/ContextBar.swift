import Foundation

/// The Context Bar (View › Show Context Bar, 0.4.0; on by default): one thin row above the
/// editor whose buttons depend on the file type. Declared here as data,
/// so the Mac bar (and later the iPad keyboard row) draw the same items.
/// Each item names a main-menu command by its action selector: a button
/// runs that menu item, so every bar button is also a menu and palette
/// command, with the same validation and one undo step.
public struct ContextBarItem: Equatable, Sendable {
    /// A menu command: the action selector's name, and the item's title
    /// (it tells apart items that share an action).
    public struct Command: Equatable, Sendable {
        public var command: String
        public var title: String
    }

    /// Stable id (accessibility identifier "contextbar.<id>").
    public var id: String
    /// SF Symbol.
    public var symbol: String
    /// The command a click runs; nil for a pull-down (`choices`).
    public var command: String?
    /// A pull-down's commands (heading levels).
    public var choices: [Command]
    /// Right of the divider (view toggles rather than formatting).
    public var trailing: Bool
    /// Shows an on/off state (the menu item's checkmark).
    public var toggle: Bool

    init(_ id: String, _ symbol: String, _ command: String?, choices: [Command] = [], trailing: Bool = false, toggle: Bool = false) {
        self.id = id
        self.symbol = symbol
        self.command = command
        self.choices = choices
        self.trailing = trailing
        self.toggle = toggle
    }
}

public enum ContextBarSet {
    /// Markdown: heading pull-down, inline styles, lists, blocks, then the preview.
    static let markdown: [ContextBarItem] = [
        ContextBarItem("heading", "textformat.size", nil, choices: [
            .init(command: "markdownBodyMenu:", title: "Body"),
            .init(command: "markdownHeading1Menu:", title: "Heading 1"),
            .init(command: "markdownHeading2Menu:", title: "Heading 2"),
            .init(command: "markdownHeading3Menu:", title: "Heading 3"),
        ]),
        ContextBarItem("bold", "bold", "markdownBoldMenu:"),
        ContextBarItem("italic", "italic", "markdownItalicMenu:"),
        ContextBarItem("strikethrough", "strikethrough", "markdownStrikethroughMenu:"),
        ContextBarItem("code", "chevron.left.forwardslash.chevron.right", "markdownCodeMenu:"),
        ContextBarItem("link", "link", "markdownLinkMenu:"),
        ContextBarItem("bulletList", "list.bullet", "markdownBulletListMenu:"),
        ContextBarItem("numberedList", "list.number", "markdownNumberedListMenu:"),
        ContextBarItem("checkbox", "checklist", "toggleCheckboxMenu:"),
        ContextBarItem("quote", "text.quote", "markdownQuoteMenu:"),
        ContextBarItem("codeBlock", "curlybraces.square", "markdownCodeBlockMenu:"),
        ContextBarItem("table", "tablecells", "markdownTableMenu:"),
        ContextBarItem("image", "photo", "markdownImageMenu:"),
        // An eye, not "sidebar.right" (read as a sidebar toggle, UX review #21).
        ContextBarItem("preview", "eye", "togglePreview:", trailing: true, toggle: true),
        ContextBarItem("explain", "text.magnifyingglass", "explainSelectionMenu:", trailing: true),
        ContextBarItem("rewrite", "pencil.line", "rewriteSelectionMenu:", trailing: true),
    ]

    /// The bar's items for `language`; empty: no bar (general code, plain
    /// text, and the types whose sets aren't built yet).
    public static func items(for language: Language) -> [ContextBarItem] {
        switch language {
        case .markdown: return markdown
        default: return []
        }
    }

    public static func hasBar(_ language: Language) -> Bool { !items(for: language).isEmpty }
}
