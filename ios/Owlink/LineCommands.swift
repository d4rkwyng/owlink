import UIKit
import CedricCore

extension EditorViewController {
    var lineEditable: Bool {
        editGate.isEditable && textView.isEditable && textView.markedTextRange == nil
    }

    static let lineActions: Set<Selector> = [
        #selector(duplicateLine(_:)), #selector(deleteLine(_:)), #selector(moveLineUp(_:)),
        #selector(moveLineDown(_:)), #selector(commentSelection(_:)), #selector(indentLines(_:)),
        #selector(outdentLines(_:)), #selector(convertIndentationToSpaces(_:)), #selector(convertIndentationToTabs(_:)),
        #selector(keepLinesMatching(_:)), #selector(deleteLinesMatching(_:)),
    ]

    /// `moveBy`: Move Line Up (-1) / Down (+1); the moved lines take
    /// their bookmarks along.
    private func lineEdit(_ name: String, moveBy: Int? = nil, _ transform: (NSString, NSRange) -> TextEdit?) {
        guard lineEditable else { return }
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length,
              let edit = transform(text, selection) else { return }
        var moved: Bookmarks?
        if let moveBy, !bookmarks.isEmpty {
            let block = LineOperations.lineBlock(selection, in: text)
            let firstLine = lineIndex.line(containing: block.location)
            let lastLine = block.length == 0 ? firstLine : lineIndex.line(containing: NSMaxRange(block) - 1)
            moved = bookmarks
            moved?.moveLines(firstLine..<(lastLine + 1), by: moveBy)
        }
        applyTextEdit(edit, actionName: name, bookmarks: moved)
    }

    @objc func duplicateLine(_ sender: Any?) {
        lineEdit(String(localized: "Duplicate Line")) { LineOperations.duplicate($1, in: $0) }
    }
    @objc func deleteLine(_ sender: Any?) {
        lineEdit(String(localized: "Delete Line")) { LineOperations.deleteLines($1, in: $0) }
    }
    @objc func moveLineUp(_ sender: Any?) {
        lineEdit(String(localized: "Move Line Up"), moveBy: -1) { LineOperations.moveUp($1, in: $0) }
    }
    @objc func moveLineDown(_ sender: Any?) {
        lineEdit(String(localized: "Move Line Down"), moveBy: 1) { LineOperations.moveDown($1, in: $0) }
    }
    @objc func commentSelection(_ sender: Any?) {
        lineEdit(String(localized: "Comment Selection")) {
            LineOperations.toggleComment($1, in: $0, syntax: document.language.language.commentSyntax)
        }
    }

    func resolvedLineIndentation(_ text: NSString) -> (indentation: Indentation, tabTypesSpaces: Bool) {
        return LanguageIndent.resolve(language: document.language.language, manual: lineIndentation,
                                      detected: detectedIndentation(for: text), default: AppSettings.defaultIndentation,
                                      defaultSaved: AppSettings.defaults.object(forKey: AppSettings.Key.indentWithTabs) != nil)
    }

    func currentLineIndentation(_ text: NSString) -> Indentation { resolvedLineIndentation(text).indentation }

    @objc func indentLines(_ sender: Any?) {
        lineEdit(String(localized: "Indent")) { text, selection in
            LineOperations.indent(selection, in: text, unit: currentLineIndentation(text).unit)
        }
    }
    @objc func outdentLines(_ sender: Any?) {
        lineEdit(String(localized: "Outdent")) { text, selection in
            LineOperations.outdent(selection, in: text, width: currentLineIndentation(text).width)
        }
    }
    private func convertIndentation(toTabs: Bool) {
        guard lineEditable else { return }
        let text = textView.textStorage.string as NSString
        let from = currentLineIndentation(text)
        let to = Indentation(usesTabs: toTabs, width: from.width)
        let converted = LineOperations.convertIndentation(text as String, from: from, to: to)
        guard converted != text as String || lineIndentation != to else { return }
        let selection = NSRange(location: min(textView.selectedRange.location, (converted as NSString).length), length: 0)
        let edit = converted == text as String
            ? TextEdit(range: NSRange(location: 0, length: 0), replacement: "", selection: textView.selectedRange)
            : TextEdit(range: NSRange(location: 0, length: text.length), replacement: converted, selection: selection)
        applyTextEdit(edit,
                      actionName: toTabs ? String(localized: "Convert Indentation to Tabs") : String(localized: "Convert Indentation to Spaces"),
                      indentation: IndentationChange(value: to))
    }
    @objc func convertIndentationToSpaces(_ sender: Any?) { convertIndentation(toTabs: false) }
    @objc func convertIndentationToTabs(_ sender: Any?) { convertIndentation(toTabs: true) }

    /// Indent Using Spaces / Tabs, Tab Width: for this document until it is
    /// closed or reloaded. Not an edit: the text stays as it is (Convert
    /// Indentation rewrites it).
    static let indentationModeActions: Set<Selector> = [
        #selector(indentUsingSpaces(_:)), #selector(indentUsingTabs(_:)), #selector(tabWidthMenu(_:)),
    ]

    func setIndentation(_ ind: Indentation) {
        lineIndentation = ind
        applyTabStops()
    }

    private var indentationInEffect: Indentation { currentLineIndentation(textView.textStorage.string as NSString) }

    @objc func indentUsingSpaces(_ sender: Any?) {
        setIndentation(Indentation(usesTabs: false, width: indentationInEffect.width))
    }
    @objc func indentUsingTabs(_ sender: Any?) {
        setIndentation(Indentation(usesTabs: true, width: indentationInEffect.width))
    }
    func setTabWidth(_ width: Int) {
        setIndentation(Indentation(usesTabs: indentationInEffect.usesTabs, width: width))
    }
    /// Text › Indentation › Tab Width: n (the width is the command's
    /// property list).
    @objc func tabWidthMenu(_ sender: Any?) {
        guard let width = (sender as? UICommand)?.propertyList as? Int else { return }
        setTabWidth(width)
    }

    /// The Text › Indentation commands' checkmarks: what is in effect now.
    func validateIndentationCommand(_ command: UICommand) {
        let current = indentationInEffect
        switch command.action {
        case #selector(indentUsingSpaces(_:)): command.state = current.usesTabs ? .off : .on
        case #selector(indentUsingTabs(_:)): command.state = current.usesTabs ? .on : .off
        case #selector(tabWidthMenu(_:)): command.state = (command.propertyList as? Int) == current.width ? .on : .off
        default: break
        }
    }

    /// How wide a tab is drawn: this document's pick, else the default (no
    /// detection, as on the Mac). Tab stops every `width` spaces of the
    /// editor font, on typing and over the whole text.
    func applyTabStops() {
        let font = textView.font ?? AppSettings.font(for: document.language.language, traits: traitCollection)
        let width = lineIndentation?.width ?? AppSettings.defaultIndentation.width
        let space = (" " as NSString).size(withAttributes: [.font: font]).width
        let para = NSMutableParagraphStyle()
        para.tabStops = []
        para.defaultTabInterval = space * CGFloat(max(1, width))
        textView.typingAttributes[.paragraphStyle] = para
        let storage = textView.textStorage
        guard storage.length > 0,
              (storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.defaultTabInterval != para.defaultTabInterval
        else { return }
        // One attribute over the whole text, as a theme or font change does.
        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// Indent Using Spaces / Tabs, Tab Width: 2…8, then Convert, as on the
    /// Mac. The picks are offered whenever the editor is open (not edits);
    /// Convert only when the document can be edited.
    func indentationMenu() -> UIMenu {
        let current = indentationInEffect
        func pick(_ title: String, _ id: String, on: Bool, _ perform: @escaping (EditorViewController) -> Void) -> UIAction {
            let item = UIAction(title: title, state: on ? .on : .off) { [weak self] _ in
                guard let self else { return }
                perform(self)
            }
            item.accessibilityIdentifier = id
            return item
        }
        func convert(_ title: String, _ id: String, _ perform: @escaping (EditorViewController) -> Void) -> UIAction {
            let item = UIAction(title: title) { [weak self] _ in
                guard let self, self.lineEditable else { return }
                perform(self)
            }
            item.accessibilityIdentifier = id
            if !lineEditable { item.attributes = .disabled }
            return item
        }
        let mode = UIMenu(options: .displayInline, children: [
            pick(String(localized: "Indent Using Spaces"), "editor.indentUsingSpaces", on: !current.usesTabs) { $0.indentUsingSpaces(nil) },
            pick(String(localized: "Indent Using Tabs"), "editor.indentUsingTabs", on: current.usesTabs) { $0.indentUsingTabs(nil) },
        ])
        let widths = UIMenu(options: .displayInline, children: Indentation.widths.map { width in
            pick(String(localized: "Tab Width: \(width)"), "editor.tabWidth.\(width)", on: current.width == width) { $0.setTabWidth(width) }
        })
        return UIMenu(title: String(localized: "Indentation"), image: UIImage(systemName: "increase.indent"), children: [
            mode, widths,
            convert(String(localized: "Convert Indentation to Spaces"), "editor.convertIndentationToSpaces") { $0.convertIndentationToSpaces(nil) },
            convert(String(localized: "Convert Indentation to Tabs"), "editor.convertIndentationToTabs") { $0.convertIndentationToTabs(nil) },
        ])
    }

    func lineEditMenu() -> UIMenu {
        func action(_ title: String, enabled: Bool = true, _ perform: @escaping (EditorViewController) -> Void) -> UIAction {
            let item = UIAction(title: title) { [weak self] _ in
                guard let self, self.lineEditable else { return }
                perform(self)
            }
            if !lineEditable || !enabled { item.attributes = .disabled }
            return item
        }
        return UIMenu(title: String(localized: "Line"), children: [
            action(String(localized: "Duplicate Line")) { $0.duplicateLine(nil) },
            action(String(localized: "Delete Line")) { $0.deleteLine(nil) },
            action(String(localized: "Move Line Up")) { $0.moveLineUp(nil) },
            action(String(localized: "Move Line Down")) { $0.moveLineDown(nil) },
            action(String(localized: "Comment Selection"), enabled: document.language.language.commentSyntax != nil) { $0.commentSelection(nil) },
            action(String(localized: "Indent")) { $0.indentLines(nil) },
            action(String(localized: "Outdent")) { $0.outdentLines(nil) },
            action(String(localized: "Keep Lines Matching…")) { $0.keepLinesMatching(nil) },
            action(String(localized: "Delete Lines Matching…")) { $0.deleteLinesMatching(nil) },
            indentationMenu(),
        ])
    }

    @objc func keepLinesMatching(_ sender: Any?) { showLineFilter(keep: true) }
    @objc func deleteLinesMatching(_ sender: Any?) { showLineFilter(keep: false) }

    enum FilterOutcome: Equatable {
        case removed(Int), noChange, stale, notEditable
    }

    func filterLines(pattern: String, regex: Bool, caseSensitive: Bool, keep: Bool) async throws -> FilterOutcome {
        guard lineEditable else { return .notEditable }
        let snapshot = EditorViewController.immutableCopy(textView.textStorage) as String
        let originalGeneration = generation
        let task = Task.detached(priority: .userInitiated) {
            try LineFilter.filter(snapshot as NSString, pattern: pattern, regex: regex,
                                  caseSensitive: caseSensitive, keepMatching: keep)
        }
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard generation == originalGeneration else { return .stale }
        guard lineEditable else { return .notEditable }
        if let result {
            applyTextEdit(result.edit, actionName: keep ? String(localized: "Keep Lines Matching") : String(localized: "Delete Lines Matching"))
            return .removed(result.removed.count)
        }
        return .noChange
    }

    private func showLineFilter(keep: Bool) {
        guard lineEditable else { return }
        present(UINavigationController(rootViewController: makeLineFilter(keep: keep)), animated: true)
    }

    func makeLineFilter(keep: Bool) -> LineFilterViewController {
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        let selected = selection.length > 0 && selection.length < 200 && NSMaxRange(selection) <= text.length
            && text.rangeOfCharacter(from: .newlines, options: [], range: selection).location == NSNotFound
        let pattern = selected ? text.substring(with: selection) : (UserDefaults.standard.string(forKey: "filterLinesPattern") ?? "")
        let controller = LineFilterViewController(keep: keep, pattern: pattern) { [weak self] pattern, regex, matchCase in
            guard let self else { return String(localized: "The document is no longer available.") }
            do {
                switch try await self.filterLines(pattern: pattern, regex: regex, caseSensitive: matchCase, keep: keep) {
                case .removed(let count):
                    self.toast(count == 1 ? String(localized: "1 line removed") : String(localized: "\(count) lines removed"))
                    return nil
                case .noChange:
                    self.toast(String(localized: "No lines matched or removed."))
                    return nil
                case .stale: return String(localized: "The document changed. Try again.")
                case .notEditable: return String(localized: "This file is open read-only.")
                }
            } catch LineFilter.FilterError.emptyPattern {
                return String(localized: "Enter text or a pattern.")
            } catch LineFilter.FilterError.invalidPattern {
                return String(localized: "That isn’t a valid regular expression.")
            } catch is CancellationError {
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        return controller
    }
}

final class LineFilterViewController: UIViewController, UITextFieldDelegate {
    private let keep: Bool
    private let pattern: UITextField
    private let regex = UISwitch()
    private let matchCase = UISwitch()
    private let apply: (String, Bool, Bool) async -> String?
    private let progress = UIActivityIndicatorView(style: .medium)
    private var task: Task<Void, Never>?

    init(keep: Bool, pattern: String, apply: @escaping (String, Bool, Bool) async -> String?) {
        self.keep = keep
        self.pattern = UITextField()
        self.pattern.text = pattern
        self.apply = apply
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = keep ? String(localized: "Keep Lines Matching") : String(localized: "Delete Lines Matching")
        view.backgroundColor = .systemBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancel))
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: keep ? String(localized: "Keep") : String(localized: "Delete"),
                                                            style: .done, target: self, action: #selector(submit))
        pattern.placeholder = String(localized: "Text or pattern")
        pattern.accessibilityLabel = String(localized: "Text or pattern")
        pattern.accessibilityIdentifier = "filter.pattern"
        pattern.borderStyle = .roundedRect
        pattern.font = .preferredFont(forTextStyle: .body)
        pattern.adjustsFontForContentSizeCategory = true
        pattern.autocorrectionType = .no
        pattern.smartQuotesType = .no
        pattern.smartDashesType = .no
        pattern.spellCheckingType = .no
        pattern.autocapitalizationType = .none
        pattern.returnKeyType = .done
        pattern.clearButtonMode = .whileEditing
        pattern.delegate = self
        regex.isOn = UserDefaults.standard.bool(forKey: "filterLinesRegex")
        matchCase.isOn = UserDefaults.standard.bool(forKey: "filterLinesMatchCase")
        let message = UILabel()
        message.numberOfLines = 0
        message.font = .preferredFont(forTextStyle: .body)
        message.adjustsFontForContentSizeCategory = true
        message.text = keep ? String(localized: "Every line that doesn’t contain this is deleted.")
                            : String(localized: "Every line that contains this is deleted.")
        func row(_ title: String, _ control: UISwitch) -> UIStackView {
            let label = UILabel()
            label.text = title
            label.font = .preferredFont(forTextStyle: .body)
            label.adjustsFontForContentSizeCategory = true
            label.numberOfLines = 0
            control.accessibilityLabel = title
            let stack = UIStackView(arrangedSubviews: [label, control])
            stack.distribution = .equalSpacing
            return stack
        }
        let stack = UIStackView(arrangedSubviews: [message, pattern,
            row(String(localized: "Regular expression"), regex), row(String(localized: "Match Case"), matchCase), progress])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        progress.hidesWhenStopped = true
        progress.accessibilityLabel = String(localized: "Filtering lines")
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        pattern.becomeFirstResponder()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        submit()
        return false
    }

    @objc private func cancel() {
        task?.cancel()
        dismiss(animated: true)
    }
    @objc private func submit() {
        guard task == nil else { return }
        let value = pattern.text ?? ""
        UserDefaults.standard.set(value, forKey: "filterLinesPattern")
        UserDefaults.standard.set(regex.isOn, forKey: "filterLinesRegex")
        UserDefaults.standard.set(matchCase.isOn, forKey: "filterLinesMatchCase")
        let useRegex = regex.isOn
        let sensitive = matchCase.isOn
        pattern.resignFirstResponder()
        progress.startAnimating()
        navigationItem.rightBarButtonItem?.isEnabled = false
        isModalInPresentation = true
        navigationController?.isModalInPresentation = true
        task = Task { [weak self] in
            guard let self else { return }
            let error = await self.apply(value, useRegex, sensitive)
            guard !Task.isCancelled else { return }
            self.task = nil
            self.progress.stopAnimating()
            self.navigationItem.rightBarButtonItem?.isEnabled = true
            self.isModalInPresentation = false
            self.navigationController?.isModalInPresentation = false
            if let error {
                let alert = UIAlertController(title: error, message: nil, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                self.present(alert, animated: true)
            } else {
                self.dismiss(animated: true)
            }
        }
    }
}
