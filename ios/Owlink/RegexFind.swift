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
    /// What the last search found, for the find navigator's quiet state.
    enum Status: Equatable { case idle, invalidPattern, timedOut, tooManyMatches }

    /// Matches beyond this are not highlighted.
    nonisolated static let maxHighlightedMatches = 10_000
    nonisolated static let maxReplacements = 200_000
    private static let chunk = 400
    private static let replaceAllRetries = 2

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
    /// Changes when Regex is switched or the session ends, not on edits.
    private var lifecycle = 0
    private var keepsMatches = false
    private var lastAnnounced: String?
    private(set) var enabled: Bool
    private(set) var status = Status.idle
    /// The last message shown to the person (also toasted), for tests.
    private(set) var lastMessage: String?
    /// Tests: replaces the length-scaled search time limit.
    var timeLimitOverride: TimeInterval?

    init(editor: EditorViewController) {
        self.editor = editor
        self.enabled = AppSettings.findRegex
    }

    var selectedTextRange: UITextRange? { editor?.textView.selectedTextRange }
    var supportsTextReplacement: Bool { editor?.textView.isEditable == true }

    func compare(_ foundRange: UITextRange, toRange: UITextRange, document: AnyHashable??) -> ComparisonResult {
        guard let view = editor?.textView else { return .orderedSame }
        return view.compare(foundRange, toRange: toRange, document: document)
    }

    private static func findOptions(_ options: UITextSearchOptions) -> FindOptions {
        FindOptions(regex: true,
                    caseSensitive: !options.stringCompareOptions.contains(.caseInsensitive),
                    wholeWord: options.wordMatchMethod == .fullWord,
                    wordPrefix: options.wordMatchMethod == .startsWith)
    }

    // MARK: Messages

    /// `once`: a search repeats per keystroke, so say its message once until
    /// a search succeeds again.
    private func report(_ message: String, once: Bool = false) {
        lastMessage = message
        guard let editor else { return }
        if once {
            if lastAnnounced == message { return }
            lastAnnounced = message
        }
        editor.findError(message)
    }

    private func message(for error: Error) -> String? {
        guard let error = error as? FindEngine.FindError else { return nil }
        switch error {
        case .emptyPattern, .cancelled: return nil
        case .invalidPattern: return String(localized: "Invalid pattern")
        case .timedOut: return String(localized: "The search took too long. Try a simpler expression.")
        case .tooManyMatches:
            return String(localized: "More than \(Self.maxHighlightedMatches) matches. Make the expression more specific, or use Replace All.")
        }
    }

    // MARK: Search

    func performTextSearch(queryString: String, options: UITextSearchOptions, resultAggregator: UITextSearchAggregator<AnyHashable?>) {
        lastQuery = queryString
        lastSearchOptions = options
        request += 1
        job?.cancel()
        let job = FindJob()
        self.job = job
        let token = request
        aggregator = resultAggregator
        guard let view = editor?.textView else { resultAggregator.finishedSearching(); return }
        if !enabled {
            matches = []
            expression = nil
            view.performTextSearch(queryString: queryString, options: options, resultAggregator: resultAggregator)
            return
        }
        let text = EditorViewController.immutableCopy(view.textStorage) as String
        let aggregator = FindAggregator(value: resultAggregator)
        let findOptions = Self.findOptions(options)
        let limit = timeLimitOverride ?? FindEngine.timeLimit(forLength: (text as NSString).length)
        queue.async { [weak self] in
            let result = Result {
                if job.isCancelled { throw FindEngine.FindError.cancelled }
                let regex = try FindEngine.regex(queryString, findOptions)
                return (regex, try FindEngine.boundedMatches(regex, in: text, timeLimit: limit,
                                                              maxMatches: Self.maxHighlightedMatches,
                                                              isCancelled: { job.isCancelled }))
            }
            DispatchQueue.main.async {
                guard let self, self.request == token, self.enabled,
                      let editor = self.editor, editor.textView.textStorage.string == text else {
                    aggregator.value.finishedSearching()
                    return
                }
                switch result {
                case .success(let (regex, found)):
                    self.status = .idle
                    self.lastAnnounced = nil
                    self.expression = regex
                    self.matches = found
                    self.snapshot = text
                    self.options = findOptions
                    self.deliver(found, from: 0, cursor: (editor.textView.beginningOfDocument, 0), token: token,
                                 query: queryString, aggregator: aggregator)
                case .failure(let error):
                    self.matches = []
                    self.expression = nil
                    switch error as? FindEngine.FindError {
                    case .invalidPattern: self.status = .invalidPattern
                    case .timedOut: self.status = .timedOut
                    case .tooManyMatches: self.status = .tooManyMatches
                    default: self.status = .idle
                    }
                    // An unfinished pattern while typing is quiet: no toast,
                    // no announcement; Replace says so.
                    if self.status != .invalidPattern, let text = self.message(for: error) {
                        self.report(text, once: true)
                    }
                    aggregator.value.finishedSearching()
                }
            }
        }
    }

    /// Hands the found ranges to the system a few hundred per run-loop turn,
    /// each positioned relative to the previous one, so a big result list
    /// does not block the main thread.
    private func deliver(_ found: [NSTextCheckingResult], from index: Int, cursor: (UITextPosition, Int), token: Int,
                         query: String, aggregator: FindAggregator) {
        guard request == token, enabled, let view = editor?.textView else {
            aggregator.value.finishedSearching()
            return
        }
        var cursor = cursor
        var i = index
        let stop = min(found.count, index + Self.chunk)
        while i < stop {
            let range = found[i].range
            i += 1
            guard let start = view.position(from: cursor.0, offset: range.location - cursor.1),
                  let end = view.position(from: start, offset: range.length),
                  let textRange = view.textRange(from: start, to: end) else { continue }
            cursor = (end, NSMaxRange(range))
            aggregator.value.foundRange(textRange, searchString: query, document: nil)
        }
        if i >= found.count {
            aggregator.value.finishedSearching()
            return
        }
        let next = cursor
        let from = i
        DispatchQueue.main.async { [weak self] in
            guard let self else { aggregator.value.finishedSearching(); return }
            self.deliver(found, from: from, cursor: next, token: token, query: query, aggregator: aggregator)
        }
    }

    func decorate(foundTextRange range: UITextRange, document: AnyHashable??, usingStyle style: UITextSearchFoundTextStyle) {
        editor?.textView.decorate(foundTextRange: range, document: document, usingStyle: style)
    }

    func clearAllDecoratedFoundText() {
        editor?.textView.clearAllDecoratedFoundText()
    }

    // MARK: Replace

    func shouldReplace(foundTextRange range: UITextRange, document: AnyHashable??, withText replacementText: String) -> Bool {
        guard let view = editor?.textView, view.isEditable else { return false }
        return enabled || view.shouldReplace(foundTextRange: range, document: document, withText: replacementText)
    }

    /// Replace and Replace All say so, rather than doing nothing, when the
    /// person is composing text in the editor.
    private func refusesWhileComposing() -> Bool {
        guard editor?.textView.markedTextRange != nil else { return false }
        report(String(localized: "Finish entering text before replacing."))
        return true
    }

    func replace(foundTextRange range: UITextRange, document: AnyHashable??, withText replacementText: String) {
        guard let editor, editor.textView.isEditable else { return }
        let view = editor.textView
        guard enabled else {
            view.replace(foundTextRange: range, document: document, withText: replacementText)
            return
        }
        guard !refusesWhileComposing() else { return }
        let location = view.offset(from: view.beginningOfDocument, to: range.start)
        let length = view.offset(from: range.start, to: range.end)
        guard view.textStorage.string == snapshot, let expression,
              let index = matches.firstIndex(where: { $0.range == NSRange(location: location, length: length) }) else { return }
        let match = matches[index]
        let replacement = FindEngine.replacement(for: match, in: snapshot as NSString, template: replacementText,
                                                  regex: expression, options: options)
        // The matches after this one move by the length change, so a second
        // Replace straight away needs no new search.
        let delta = (replacement as NSString).length - match.range.length
        var remaining = matches
        remaining.remove(at: index)
        for j in index..<remaining.count { remaining[j] = remaining[j].adjustingRanges(offset: delta) }
        keepsMatches = true
        let applied = editor.applyFindReplacement(range: match.range, replacement: replacement, name: String(localized: "Replace"))
        keepsMatches = false
        if applied {
            matches = remaining
            snapshot = EditorViewController.immutableCopy(view.textStorage) as String
        }
    }

    func replaceAll(queryString: String, options: UITextSearchOptions, withText replacementText: String) {
        guard let editor, editor.textView.isEditable else { return }
        guard enabled else {
            editor.textView.replaceAll(queryString: queryString, options: options, withText: replacementText)
            return
        }
        guard !refusesWhileComposing() else { return }
        replacementJob?.cancel()
        runReplaceAll(query: queryString, findOptions: Self.findOptions(options), template: replacementText, attempt: 0)
    }

    private func runReplaceAll(query: String, findOptions: FindOptions, template: String, attempt: Int) {
        guard let editor else { return }
        let text = EditorViewController.immutableCopy(editor.textView.textStorage) as String
        let generation = lifecycle
        let limit = timeLimitOverride ?? FindEngine.timeLimit(forLength: (text as NSString).length, interactive: false)
        let job = FindJob()
        replacementJob = job
        queue.async { [weak self] in
            let result = Result { () -> [(range: NSRange, replacement: String)] in
                if job.isCancelled { throw FindEngine.FindError.cancelled }
                let regex = try FindEngine.regex(query, findOptions)
                let matches = try FindEngine.boundedMatches(regex, in: text, timeLimit: limit, maxMatches: Self.maxReplacements,
                                                            isCancelled: { job.isCancelled })
                let ns = text as NSString
                var edits: [(range: NSRange, replacement: String)] = []
                edits.reserveCapacity(matches.count)
                for (n, match) in matches.enumerated() {
                    if n % 1000 == 0, job.isCancelled { throw FindEngine.FindError.cancelled }
                    edits.append((match.range, FindEngine.replacement(for: match, in: ns, template: template, regex: regex, options: findOptions)))
                }
                return edits
            }
            DispatchQueue.main.async {
                guard let self, self.enabled, self.lifecycle == generation, !job.isCancelled, let editor = self.editor else { return }
                guard editor.textView.isEditable else {
                    self.report(String(localized: "The document is read-only."))
                    return
                }
                guard editor.textView.textStorage.string == text else {
                    // Edited while searching: search again on the new text.
                    if attempt < Self.replaceAllRetries {
                        self.runReplaceAll(query: query, findOptions: findOptions, template: template, attempt: attempt + 1)
                    } else {
                        self.report(String(localized: "The document kept changing, so nothing was replaced. Try Replace All again."))
                    }
                    return
                }
                switch result {
                case .success(let edits):
                    guard !edits.isEmpty, !self.refusesWhileComposing() else { return }
                    if !editor.applyFindReplacements(edits, name: String(localized: "Replace All")) {
                        self.report(String(localized: "Nothing was replaced."))
                    }
                case .failure(let error):
                    if error as? FindEngine.FindError == .tooManyMatches {
                        self.report(String(localized: "Too many replacements (\(Self.maxReplacements)+). Narrow the pattern."))
                    } else if let text = self.message(for: error) { self.report(text) }
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

    // MARK: Lifecycle

    /// The text changed: search again. After Find's own single replacement
    /// the shifted matches stay usable meanwhile.
    func invalidate() {
        request += 1
        job?.cancel()
        if !keepsMatches {
            matches = []
            expression = nil
        }
        if let session, let lastQuery, let lastSearchOptions {
            session.performSearch(query: lastQuery, options: lastSearchOptions)
        } else {
            aggregator?.invalidate()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard self.enabled != enabled else { return }
        self.enabled = enabled
        AppSettings.findRegex = enabled
        request += 1
        lifecycle += 1
        job?.cancel()
        replacementJob?.cancel()
        matches = []
        expression = nil
        status = .idle
        lastAnnounced = nil
        if let session, let lastQuery, let lastSearchOptions {
            session.performSearch(query: lastQuery, options: lastSearchOptions)
        } else {
            aggregator?.invalidate()
        }
    }

    func endSession() {
        request += 1
        lifecycle += 1
        job?.cancel()
        replacementJob?.cancel()
        aggregator = nil
        lastQuery = nil
        lastSearchOptions = nil
        session = nil
        matches = []
        expression = nil
        status = .idle
        lastAnnounced = nil
    }
}
