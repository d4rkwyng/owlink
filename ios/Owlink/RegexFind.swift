import UIKit
import CedricCore

private final class FindJob: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
}

// UIKit documents the aggregator as thread-safe; it is only used on the
// main actor after the background search finishes.
private struct FindAggregator: @unchecked Sendable {
    let value: UITextSearchAggregator<AnyHashable?>
}

@MainActor
final class RegexFind: NSObject, @preconcurrency UITextSearching {
    private weak var editor: EditorViewController?
    private var aggregator: UITextSearchAggregator<AnyHashable?>?
    private var request = 0
    private var snapshot = ""
    private var expression: NSRegularExpression?
    private var matches: [NSTextCheckingResult] = []
    private var options = FindOptions(regex: true)
    private var lastQuery: String?
    private var lastSearchOptions: UITextSearchOptions?
    weak var session: UIFindSession?
    private let queue = DispatchQueue(label: "app.owlink.regexFind", qos: .userInitiated)
    private var job: FindJob?
    private var replacementJob: FindJob?
    private var editEpoch = 0
    private(set) var enabled = false

    init(editor: EditorViewController) {
        self.editor = editor
    }

    var selectedTextRange: UITextRange? { editor?.textView.selectedTextRange }
    var supportsTextReplacement: Bool { editor?.textView.isEditable == true }

    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: AnyHashable??) -> ComparisonResult {
        guard let view = editor?.textView else { return .orderedSame }
        return view.compare(foundRange, toRange: toRange, document: document)
    }

    func performTextSearch(queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<AnyHashable?>) {
        lastQuery = queryString
        lastSearchOptions = options
        request += 1
        job?.cancel()
        let job = FindJob()
        self.job = job
        let token = request
        aggregator = resultAggregator
        matches = []
        expression = nil
        guard let view = editor?.textView else { resultAggregator.finishedSearching(); return }
        if !enabled {
            view.performTextSearch(queryString: queryString, options: options, resultAggregator: resultAggregator)
            return
        }
        let text = view.textStorage.string
        let aggregator = FindAggregator(value: resultAggregator)
        snapshot = text
        let findOptions = FindOptions(regex: true,
                                      caseSensitive: !options.stringCompareOptions.contains(.caseInsensitive),
                                      wholeWord: options.wordMatchMethod == .fullWord)
        self.options = findOptions
        queue.async { [weak self] in
            let result = Result {
                if job.isCancelled { throw FindEngine.FindError.cancelled }
                let regex = try FindEngine.regex(queryString, findOptions)
                return (regex, try FindEngine.boundedMatches(regex, in: text, isCancelled: { job.isCancelled }))
            }
            DispatchQueue.main.async {
                guard let self, self.request == token, self.enabled,
                      let editor = self.editor, editor.textView.textStorage.string == text else {
                    aggregator.value.finishedSearching()
                    return
                }
                switch result {
                case .success(let (regex, matches)):
                    self.expression = regex
                    self.matches = matches
                    for match in matches {
                        if let range = self.textRange(match.range, in: editor.textView) {
                            aggregator.value.foundRange(range, searchString: queryString, document: nil)
                        }
                    }
                case .failure(let error):
                    if case FindEngine.FindError.emptyPattern = error {
                    } else if case FindEngine.FindError.invalidPattern = error {
                        editor.findError(String(localized: "Invalid pattern"))
                    } else {
                        editor.findError(String(localized: "The search took too long or found too many matches. Try a simpler expression."))
                    }
                }
                aggregator.value.finishedSearching()
            }
        }
    }

    func decorate(foundTextRange range: UITextRange, document: AnyHashable??, usingStyle style: UITextSearchFoundTextStyle) {
        editor?.textView.decorate(foundTextRange: range, document: document, usingStyle: style)
    }

    func clearAllDecoratedFoundText() {
        editor?.textView.clearAllDecoratedFoundText()
    }

    func shouldReplace(foundTextRange range: UITextRange, document: AnyHashable??, withText replacementText: String) -> Bool {
        guard let view = editor?.textView, view.isEditable else { return false }
        return enabled || view.shouldReplace(foundTextRange: range, document: document, withText: replacementText)
    }

    func replace(foundTextRange range: UITextRange, document: AnyHashable??, withText replacementText: String) {
        guard let editor, editor.textView.isEditable else { return }
        let view = editor.textView
        guard enabled else {
            view.replace(foundTextRange: range, document: document, withText: replacementText)
            return
        }
        let location = view.offset(from: view.beginningOfDocument, to: range.start)
        let length = view.offset(from: range.start, to: range.end)
        guard view.textStorage.string == snapshot, let expression,
              let match = matches.first(where: { $0.range == NSRange(location: location, length: length) }) else { return }
        let replacement = FindEngine.replacement(for: match, in: snapshot as NSString, template: replacementText,
                                                  regex: expression, options: options)
        editor.applyFindReplacement(range: match.range, replacement: replacement, name: String(localized: "Replace"))
    }

    func replaceAll(queryString: String, options: UITextSearchOptions, withText replacementText: String) {
        guard let editor, editor.textView.isEditable else { return }
        let view = editor.textView
        guard enabled else {
            view.replaceAll(queryString: queryString, options: options, withText: replacementText)
            return
        }
        let text = view.textStorage.string
        let findOptions = FindOptions(regex: true,
                                      caseSensitive: !options.stringCompareOptions.contains(.caseInsensitive),
                                      wholeWord: options.wordMatchMethod == .fullWord)
        let epoch = editEpoch
        replacementJob?.cancel()
        let job = FindJob()
        replacementJob = job
        queue.async { [weak self] in
            let result = Result {
                if job.isCancelled { throw FindEngine.FindError.cancelled }
                let regex = try FindEngine.regex(queryString, findOptions)
                let matches = try FindEngine.boundedMatches(regex, in: text, isCancelled: { job.isCancelled })
                guard let first = matches.first, let last = matches.last else { return (NSRange(location: 0, length: 0), "") }
                let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
                let ns = text as NSString
                let replacement = NSMutableString(string: ns.substring(with: span))
                for match in matches.reversed() {
                    if job.isCancelled { throw FindEngine.FindError.cancelled }
                    let value = FindEngine.replacement(for: match, in: ns, template: replacementText, regex: regex, options: findOptions)
                    replacement.replaceCharacters(in: NSRange(location: match.range.location - span.location, length: match.range.length), with: value)
                }
                return (span, replacement as String)
            }
            DispatchQueue.main.async {
                guard let self, self.enabled, self.editEpoch == epoch, !job.isCancelled, let editor = self.editor,
                      editor.textView.isEditable, editor.textView.textStorage.string == text else { return }
                switch result {
                case .success(let (range, replacement)):
                    if range.length > 0 {
                        editor.applyFindReplacement(range: range, replacement: replacement, name: String(localized: "Replace All"))
                    }
                case .failure(let error):
                    if case FindEngine.FindError.emptyPattern = error { return }
                    if case FindEngine.FindError.invalidPattern = error {
                        editor.findError(String(localized: "Invalid pattern"))
                    } else {
                        editor.findError(String(localized: "The search took too long or found too many matches. Try a simpler expression."))
                    }
                }
            }
        }
    }

    func willHighlight(foundTextRange range: UITextRange, document: AnyHashable??) {
        editor?.textView.willHighlight(foundTextRange: range, document: document)
    }

    func scrollRangeToVisible(_ range: UITextRange, inDocument document: AnyHashable??) {
        editor?.textView.scrollRangeToVisible(range, inDocument: document)
    }

    func invalidate() {
        request += 1
        editEpoch += 1
        job?.cancel()
        replacementJob?.cancel()
        matches = []
        expression = nil
        if let session, let lastQuery, let lastSearchOptions {
            session.performSearch(query: lastQuery, options: lastSearchOptions)
        } else {
            aggregator?.invalidate()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        request += 1
        editEpoch += 1
        job?.cancel()
        replacementJob?.cancel()
        matches = []
        expression = nil
        if let session, let lastQuery, let lastSearchOptions {
            session.performSearch(query: lastQuery, options: lastSearchOptions)
        }
    }

    func endSession() {
        request += 1
        editEpoch += 1
        job?.cancel()
        replacementJob?.cancel()
        aggregator = nil
        lastQuery = nil
        lastSearchOptions = nil
        session = nil
        matches = []
        expression = nil
    }

    private func textRange(_ range: NSRange, in view: UITextView) -> UITextRange? {
        guard let start = view.position(from: view.beginningOfDocument, offset: range.location),
              let end = view.position(from: start, offset: range.length) else { return nil }
        return view.textRange(from: start, to: end)
    }
}
