import AppKit
import CedricCore

/// Colours the text view from the highlight engine: only the lines near
/// the viewport (the visible range plus a margin), as foreground-colour
/// attributes on the text storage. (v0 used TextKit 2 rendering attributes;
/// typed text was invisible on screen in Derek's test build, so colouring
/// now goes through the ordinary attribute path that TextKit 2 re-lays out
/// and redraws like any edit. Attribute changes made directly on the
/// storage are not registered with undo.) Tracks which lines are coloured so
/// scrolling back is free; an edit uncolours from the edited line down
/// (or only the edited lines for languages without cross-line state).
@MainActor
final class SyntaxColorizer {
    private weak var textView: EditorTextView?
    /// View › Split Editor's second pane: its viewport is coloured too
    /// (the colours are storage attributes, which both panes show).
    weak var secondTextView: EditorTextView?
    let engine: HighlightEngine
    private var colored = IndexSet()
    /// For the checks.
    func isColored(_ line: Int) -> Bool { colored.contains(line) }
    private var colors: [TokenKind: NSColor] = [:]
    private var foreground: NSColor = .textColor
    private var pending = false
    /// Large mode: no colouring at all (the text keeps the theme's colour).
    var paused = false
    /// Lines beyond the viewport to colour, above and below.
    static let margin = 80

    init(textView: EditorTextView, language: Language) {
        self.textView = textView
        engine = HighlightEngine(language: language)
    }

    func setPalette(_ p: EditorPalette) {
        colors = Dictionary(uniqueKeysWithValues: TokenKind.allCases.map { ($0, NSColor(hex: p.color(for: $0))) })
        foreground = NSColor(hex: p.foreground)
        recolorAll()
    }

    func setLanguage(_ l: Language) {
        engine.setLanguage(l)
        recolorAll()
    }

    func recolorAll() {
        guard let tv = textView, let storage = tv.textStorage else { return }
        colored = IndexSet()
        engine.invalidateAll()
        // Paused: the text already has the theme colour (set with the text
        // or by applyAppearance); restyling 636 K characters would cost a
        // full relayout.
        if paused { return }
        if storage.length > 0, !tv.hasMarkedText() {
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: 0, length: storage.length))
            storage.endEditing()
            fullPasses &+= 1
        }
        colorViewport()
    }

    /// For the checks: whole-text recolour passes made.
    private(set) var fullPasses = 0

    /// After an edit: lines `firstLine...lastLine` (after the edit) changed;
    /// `lineDelta` lines were added (+) or removed (−). A replacement of
    /// several lines by as many (Replace All, Toggle Comment, a pasted
    /// block) changes every one of them, not only the first: they were
    /// left in the plain text colour, still marked as coloured.
    func textDidChange(firstLine: Int, lastLine: Int? = nil, lineDelta: Int, lineCount: Int) {
        engine.invalidate(fromLine: firstLine)
        let tokenizerCarriesState = Languages.tokenizer(for: engine.language).carriesState
        if tokenizerCarriesState || lineDelta != 0 {
            colored.remove(integersIn: firstLine..<Int.max)
        } else {
            colored.remove(integersIn: firstLine...max(firstLine, lastLine ?? firstLine))
        }
        scheduleViewport()
    }

    /// Coalesces requests to one pass per run-loop turn.
    func scheduleViewport() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.colorViewport()
        }
    }

    var lineIndexProvider: () -> LineIndex = { LineIndex() }

    /// Colours whatever near the viewport isn't coloured yet. Returns the
    /// number of lines coloured (for the perf hooks).
    @discardableResult
    func colorViewport() -> Int {
        guard !paused, let tv = textView, let storage = tv.textStorage else { return 0 }
        let second = secondTextView
        // Never restyle under an input method's marked text: try again later.
        if tv.hasMarkedText() || second?.hasMarkedText() == true { scheduleLater(); return 0 }
        guard storage.editedMask.isEmpty else { scheduleViewport(); return 0 }
        let ranges = [tv.visibleCharacterRange, second?.visibleCharacterRange].compactMap { $0 }
        guard !ranges.isEmpty else { return 0 }
        let index = lineIndexProvider()
        guard index.length == storage.length else { scheduleViewport(); return 0 }
        var todo = IndexSet()
        for vr in ranges {
            let first = max(0, index.line(containing: vr.location) - Self.margin)
            let last = min(index.lineCount, index.line(containing: vr.location + vr.length) + Self.margin + 1)
            if last > first { todo.insert(integersIn: first..<last) }
        }
        todo.subtract(colored)
        guard !todo.isEmpty else { return 0 }
        let text = storage.string as NSString
        var count = 0
        storage.beginEditing()
        for r in todo.rangeView {
            // The theme's text colour on these lines, then the tokens' colours.
            let start = index.starts[r.lowerBound]
            let end = r.upperBound < index.lineCount ? index.starts[r.upperBound] : index.length
            if end > start { storage.addAttribute(.foregroundColor, value: foreground, range: NSRange(location: start, length: end - start)) }
            let tokens = engine.tokens(forLines: r, in: text, index: index)
            for t in tokens {
                guard let c = colors[t.kind], t.start + t.length <= storage.length else { continue }
                storage.addAttribute(.foregroundColor, value: c, range: NSRange(location: t.start, length: t.length))
            }
            count += r.count
        }
        storage.endEditing()
        colored.formUnion(todo)
        return count
    }

    private func scheduleLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.scheduleViewport() }
    }
}
