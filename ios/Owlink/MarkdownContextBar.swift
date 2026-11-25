import UIKit
import SwiftUI
import CedricCore

final class MarkdownContextBar: UIView {
    let items = ContextBarSet.items(for: .markdown)
    private(set) var buttons: [String: UIButton] = [:]
    private weak var editor: EditorViewController?
    private var palette = EditorPalettes.light

    init(editor: EditorViewController) {
        self.editor = editor
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 44))
        accessibilityIdentifier = "contextbar"
        accessibilityLabel = String(localized: "Context Bar")
        isAccessibilityElement = false
        accessibilityContainerType = .semanticGroup
        addInteraction(UILargeContentViewerInteraction())
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            scroll.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            stack.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
        ])
        var trailing = false
        for item in items {
            if item.trailing && !trailing {
                trailing = true
                let spacer = UIView()
                spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
                stack.addArrangedSubview(spacer)
                let divider = UIView()
                divider.backgroundColor = .separator
                divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
                divider.heightAnchor.constraint(equalToConstant: 20).isActive = true
                stack.addArrangedSubview(divider)
            }
            let button = UIButton(configuration: .plain())
            button.setImage(UIImage(systemName: item.symbol), for: .normal)
            button.accessibilityIdentifier = "contextbar.\(item.id)"
            button.accessibilityLabel = Self.label(item.id)
            button.showsLargeContentViewer = true
            button.largeContentTitle = Self.label(item.id)
            button.isPointerInteractionEnabled = true
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            if !item.choices.isEmpty {
                button.menu = UIMenu(children: item.choices.map { choice in
                    UIAction(title: Self.choiceLabel(choice.command)) { [weak self] _ in self?.run(choice.command) }
                })
                button.showsMenuAsPrimaryAction = true
            } else if let command = item.command {
                button.addAction(UIAction { [weak self] _ in self?.run(command) }, for: .touchUpInside)
            }
            buttons[item.id] = button
            stack.addArrangedSubview(button)
        }
        let rule = UIView()
        rule.backgroundColor = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)
        NSLayoutConstraint.activate([
            rule.topAnchor.constraint(equalTo: topAnchor), rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor), rule.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale),
        ])
        applyPalette(editor.palette)
        refreshStates()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { refreshStates() }
        editor?.view.setNeedsLayout()
    }

    /// Runs the bar item's command. Markdown commands refresh the bar
    /// themselves (markdownEdit) and togglePreview does via its own path;
    /// Explain and Rewrite refresh here, since Ask Cedric's running state
    /// changes what they enable.
    private func run(_ command: String) {
        guard let editor else { return }
        switch command {
        case "togglePreview:": editor.togglePreview()
        case "explainSelectionMenu:": editor.explainSelection(); refreshStates()
        case "rewriteSelectionMenu:": editor.rewriteSelection(); refreshStates()
        default:
            let action = NSSelectorFromString(command)
            if editor.canPerformAction(action, withSender: nil) { _ = editor.perform(action, with: nil) }
        }
    }

    func refreshStates() {
        guard let editor else { return }
        for item in items {
            guard let button = buttons[item.id] else { continue }
            switch item.id {
            case "preview":
                button.isEnabled = editor.document.language.language == .markdown
                button.isSelected = editor.previewOn
                button.accessibilityValue = editor.previewOn ? String(localized: "on") : String(localized: "off")
            case "explain", "rewrite": break
            default: button.isEnabled = editor.markdownEditable
            }
        }
        refreshInlineSelectionStates()
        tint()
    }

    func refreshInlineSelectionStates() {
        guard let editor else { return }
        let selection = editor.textView.selectedRange
        let states = editor.inlineAssistStates(selection: selection)
        buttons["explain"]?.isEnabled = states.explain
        buttons["rewrite"]?.isEnabled = states.rewrite
        let storage = editor.textView.textStorage
        let index = editor.lineIndex
        guard selection.location != NSNotFound, selection.location <= index.length,
              index.length == storage.length else {
            buttons["heading"]?.accessibilityValue = nil
            return
        }
        let range = index.contentRange(ofLine: index.line(containing: selection.location))
        guard range.length <= 4096 else {
            buttons["heading"]?.accessibilityValue = nil
            return
        }
        let line = storage.attributedSubstring(from: range).string
        switch MarkdownBlocks.heading(line)?.level {
        case 1: buttons["heading"]?.accessibilityValue = String(localized: "Heading 1")
        case 2: buttons["heading"]?.accessibilityValue = String(localized: "Heading 2")
        case 3: buttons["heading"]?.accessibilityValue = String(localized: "Heading 3")
        case 4: buttons["heading"]?.accessibilityValue = String(localized: "Heading 4")
        case 5: buttons["heading"]?.accessibilityValue = String(localized: "Heading 5")
        case 6: buttons["heading"]?.accessibilityValue = String(localized: "Heading 6")
        default: buttons["heading"]?.accessibilityValue = String(localized: "Body")
        }
    }

    func applyPalette(_ palette: EditorPalette) {
        self.palette = palette
        backgroundColor = UIColor(hex: palette.statusBar)
        tint()
    }

    private func tint() {
        for button in buttons.values {
            button.tintColor = UIColor(hex: button.isSelected ? palette.contextBarIconOn : palette.contextBarIcon)
        }
    }

    private static func choiceLabel(_ command: String) -> String {
        switch command {
        case "markdownBodyMenu:": return String(localized: "Body")
        case "markdownHeading1Menu:": return String(localized: "Heading 1")
        case "markdownHeading2Menu:": return String(localized: "Heading 2")
        default: return String(localized: "Heading 3")
        }
    }

    private static func label(_ id: String) -> String {
        switch id {
        case "heading": return String(localized: "Heading")
        case "bold": return String(localized: "Bold")
        case "italic": return String(localized: "Italic")
        case "strikethrough": return String(localized: "Strikethrough")
        case "code": return String(localized: "Inline Code")
        case "link": return String(localized: "Link")
        case "bulletList": return String(localized: "Bulleted List")
        case "numberedList": return String(localized: "Numbered List")
        case "checkbox": return String(localized: "Checkbox")
        case "quote": return String(localized: "Quote")
        case "codeBlock": return String(localized: "Code Block")
        case "table": return String(localized: "Insert Table")
        case "image": return String(localized: "Image Link")
        case "preview": return String(localized: "Preview")
        case "explain": return String(localized: "Explain Selection")
        case "rewrite": return String(localized: "Rewrite Selection")
        default: return id
        }
    }
}

extension EditorViewController {
    /// Makes or drops the bar for the setting and the language, and puts
    /// it on the keyboard unless the Ask Cedric sheet is up (the same bar
    /// comes back when the sheet goes).
    func updateContextBar() {
        let wanted = AppSettings.showContextBar && ContextBarSet.hasBar(document.language.language)
        if wanted, contextBar == nil {
            contextBar = MarkdownContextBar(editor: self)
        } else if !wanted, contextBar != nil {
            contextBar = nil
        }
        let attached: UIView? = contextBarHiddenForAsk ? nil : contextBar
        guard textView.inputAccessoryView !== attached else { return }
        textView.inputAccessoryView = attached
        if textView.isFirstResponder { textView.reloadInputViews() }
    }
}

/// The Ask Cedric sheet's host: says when it has gone, by any path (Done
/// calls SwiftUI's dismiss, which the sheet delegate never hears about;
/// swipe down; dismissed by its presenter).
final class AskSheetHost: UIHostingController<AskCedricView> {
    var onGone: (() -> Void)?

    /// ⌘, here too: with the sheet (or its field) holding the keys, the
    /// system's ⌘, opened the system Settings app (0.5.2 (18)). It goes
    /// up the chain to the editor's navigation controller, which hands it
    /// to the editor's `showSettings` (see `EditorCommandRouting`).
    override var keyCommands: [UIKeyCommand]? {
        (super.keyCommands ?? []) + [MenuBar.settingsKey()]
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            let gone = onGone
            onGone = nil
            gone?()
        }
    }
}
