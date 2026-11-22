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

    private func lineEdit(_ name: String, _ transform: (NSString, NSRange) -> TextEdit?) {
        guard lineEditable else { return }
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        guard selection.location != NSNotFound, NSMaxRange(selection) <= text.length,
              let edit = transform(text, selection) else { return }
        applyTextEdit(edit, actionName: name)
    }

    @objc func duplicateLine(_ sender: Any?) {
        lineEdit(String(localized: "Duplicate Line")) { LineOperations.duplicate($1, in: $0) }
    }
    @objc func deleteLine(_ sender: Any?) {
        lineEdit(String(localized: "Delete Line")) { LineOperations.deleteLines($1, in: $0) }
    }
    @objc func moveLineUp(_ sender: Any?) {
        lineEdit(String(localized: "Move Line Up")) { LineOperations.moveUp($1, in: $0) }
    }
    @objc func moveLineDown(_ sender: Any?) {
        lineEdit(String(localized: "Move Line Down")) { LineOperations.moveDown($1, in: $0) }
    }
    @objc func commentSelection(_ sender: Any?) {
        lineEdit(String(localized: "Comment Selection")) {
            LineOperations.toggleComment($1, in: $0, syntax: document.language.language.commentSyntax)
        }
    }

    func currentLineIndentation(_ text: NSString) -> Indentation {
        let defaults = UserDefaults.standard
        let width = defaults.integer(forKey: "tabWidth")
        let fallback = Indentation(usesTabs: defaults.bool(forKey: "indentWithTabs"), width: width > 0 ? width : 4)
        return LanguageIndent.resolve(language: document.language.language, manual: lineIndentation,
                                      detected: detectedIndentation(for: text), default: fallback,
                                      defaultSaved: defaults.object(forKey: "indentWithTabs") != nil).indentation
    }

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
        lineIndentation = to
        guard converted != text as String else { return }
        let selection = NSRange(location: min(textView.selectedRange.location, (converted as NSString).length), length: 0)
        applyTextEdit(TextEdit(range: NSRange(location: 0, length: text.length), replacement: converted, selection: selection),
                      actionName: toTabs ? String(localized: "Convert Indentation to Tabs") : String(localized: "Convert Indentation to Spaces"))
    }
    @objc func convertIndentationToSpaces(_ sender: Any?) { convertIndentation(toTabs: false) }
    @objc func convertIndentationToTabs(_ sender: Any?) { convertIndentation(toTabs: true) }

    func lineEditMenu() -> UIMenu {
        func action(_ title: String, _ perform: @escaping (EditorViewController) -> Void) -> UIAction {
            let item = UIAction(title: title) { [weak self] _ in
                guard let self, self.lineEditable else { return }
                perform(self)
            }
            if !lineEditable { item.attributes = .disabled }
            return item
        }
        return UIMenu(title: String(localized: "Line"), children: [
            action(String(localized: "Duplicate Line")) { $0.duplicateLine(nil) },
            action(String(localized: "Delete Line")) { $0.deleteLine(nil) },
            action(String(localized: "Move Line Up")) { $0.moveLineUp(nil) },
            action(String(localized: "Move Line Down")) { $0.moveLineDown(nil) },
            action(String(localized: "Comment Selection")) { $0.commentSelection(nil) },
        ])
    }

    @objc func keepLinesMatching(_ sender: Any?) { showLineFilter(keep: true) }
    @objc func deleteLinesMatching(_ sender: Any?) { showLineFilter(keep: false) }

    @discardableResult
    func filterLines(pattern: String, regex: Bool, caseSensitive: Bool, keep: Bool) throws -> Int? {
        guard lineEditable else { return nil }
        let result = try LineFilter.filter(textView.textStorage.string as NSString, pattern: pattern,
                                           regex: regex, caseSensitive: caseSensitive, keepMatching: keep)
        if let result {
            applyTextEdit(result.edit, actionName: keep ? String(localized: "Keep Lines Matching") : String(localized: "Delete Lines Matching"))
        }
        return result?.removed.count ?? 0
    }

    private func showLineFilter(keep: Bool) {
        guard lineEditable else { return }
        let text = textView.textStorage.string as NSString
        let selection = textView.selectedRange
        let selected = selection.length > 0 && selection.length < 200 && NSMaxRange(selection) <= text.length
            && text.rangeOfCharacter(from: .newlines, options: [], range: selection).location == NSNotFound
        let pattern = selected ? text.substring(with: selection) : (UserDefaults.standard.string(forKey: "filterLinesPattern") ?? "")
        let controller = LineFilterViewController(keep: keep, pattern: pattern) { [weak self] pattern, regex, matchCase in
            guard let self, self.lineEditable else { return String(localized: "This file is open read-only.") }
            do {
                let count = try self.filterLines(pattern: pattern, regex: regex, caseSensitive: matchCase, keep: keep) ?? 0
                self.toast(count == 1 ? String(localized: "1 line removed") : String(localized: "\(count) lines removed"))
                return nil
            } catch LineFilter.FilterError.emptyPattern {
                return String(localized: "Enter text or a pattern.")
            } catch {
                return String(localized: "That isn’t a valid regular expression.")
            }
        }
        present(UINavigationController(rootViewController: controller), animated: true)
    }
}

private final class LineFilterViewController: UIViewController {
    private let keep: Bool
    private let pattern: UITextField
    private let regex = UISwitch()
    private let matchCase = UISwitch()
    private let apply: (String, Bool, Bool) -> String?

    init(keep: Bool, pattern: String, apply: @escaping (String, Bool, Bool) -> String?) {
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
        pattern.borderStyle = .roundedRect
        regex.isOn = UserDefaults.standard.bool(forKey: "filterLinesRegex")
        matchCase.isOn = UserDefaults.standard.bool(forKey: "filterLinesMatchCase")
        let message = UILabel()
        message.numberOfLines = 0
        message.text = keep ? String(localized: "Every line that doesn’t contain this is deleted.")
                            : String(localized: "Every line that contains this is deleted.")
        func row(_ title: String, _ control: UISwitch) -> UIStackView {
            let label = UILabel()
            label.text = title
            control.accessibilityLabel = title
            let stack = UIStackView(arrangedSubviews: [label, control])
            stack.distribution = .equalSpacing
            return stack
        }
        let stack = UIStackView(arrangedSubviews: [message, pattern,
            row(String(localized: "Regular expression"), regex), row(String(localized: "Match Case"), matchCase)])
        stack.axis = .vertical
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @objc private func cancel() { dismiss(animated: true) }
    @objc private func submit() {
        let value = pattern.text ?? ""
        if let error = apply(value, regex.isOn, matchCase.isOn) {
            let alert = UIAlertController(title: error, message: nil, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            present(alert, animated: true)
            return
        }
        UserDefaults.standard.set(value, forKey: "filterLinesPattern")
        UserDefaults.standard.set(regex.isOn, forKey: "filterLinesRegex")
        UserDefaults.standard.set(matchCase.isOn, forKey: "filterLinesMatchCase")
        dismiss(animated: true)
    }
}
