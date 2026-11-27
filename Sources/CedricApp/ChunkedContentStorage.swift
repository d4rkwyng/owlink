import AppKit
import CedricCore

/// An `NSTextContentStorage` that, when `chunkLimit` is set, hands TextKit
/// paragraphs longer than the limit as several consecutive text elements
/// ("chunks") instead of one.
///
/// Why: TextKit 2 lays out a paragraph as a whole. A 636,000-character line
/// (Derek's add-on import string) is one paragraph, so every keystroke and
/// every scroll re-typesets all of it: ~100 ms per keystroke here, with or
/// without wrapping. Cut into chunks, TextKit only lays out the chunks near
/// the viewport and re-lays out only the chunk being edited.
///
/// The cost: a chunk boundary is a forced line break on screen (a wrapped
/// row ends early there, or, without wrapping, the line continues on the
/// next row). The text itself is untouched: no characters are inserted,
/// copy, save and find see the one long line. Chunks start at fixed
/// offsets from the paragraph start, nudged so they never split a
/// composed character sequence (surrogate pairs, combining marks).
///
/// The enumeration must behave exactly like NSTextContentStorage's own
/// (Scripts/chunks-check.sh compares them from every offset): lines that
/// fit are TextKit's own paragraph objects, and nothing is handed out
/// forwards from the end of the text or backwards from nil. It used to
/// hand out the last line (or chunk) forwards from the end: an element
/// lying before the location asked from. NSTextLayoutManager's
/// estimatedSizeForLastTextContainer asks from there, and that is where
/// macOS 26 raised in NSCountableTextLocation compare: while dropping the
/// layout fragments in front of the element (0.5.2 on every big log, and
/// a big log after a long-line paste).
final class ChunkedContentStorage: NSTextContentStorage {
    /// Paragraphs longer than this are split; nil: TextKit's own paragraphs.
    var chunkLimit: Int? {
        didSet { if chunkLimit != oldValue { cache.removeAll() } }
    }

    /// Chunk elements by start offset, reused until the next edit so
    /// TextKit keeps their layout. Dropped at or after an edit.
    private var cache: [Int: (range: NSRange, element: NSTextParagraph)] = [:]

    /// The line (paragraph) holding an offset, newline included. Set by the
    /// editor to its line index (O(log n)); NSString.paragraphRange scans
    /// the whole 636 K line on every call.
    var lineRange: ((Int) -> NSRange?)?

    override func processEditing(for textStorage: NSTextStorage, edited editMask: NSTextStorageEditActions,
                                 range newCharRange: NSRange, changeInLength delta: Int, invalidatedRange invalidatedCharRange: NSRange) {
        if chunkLimit != nil, !cache.isEmpty {
            // Chunks start at fixed steps from their line's start, so the
            // chunks ending before the edit keep their text and bounds;
            // the rest are rebuilt on demand.
            let at = invalidatedCharRange.location
            cache = cache.filter { NSMaxRange($0.value.range) < at }
        }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange,
                             changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    /// The chunk holding `offset` (offset == length: the last chunk).
    /// Enumeration only asks for offsets inside the text.
    /// `whole`: the line fits in one chunk.
    func chunkRange(at offset: Int, in text: NSString, limit: Int) -> (NSRange, whole: Bool) {
        let probe = min(offset, max(0, text.length - 1))
        let para = lineRange?(probe).flatMap { NSLocationInRange(probe, $0) ? $0 : nil } ?? text.paragraphRange(for: NSRange(location: probe, length: 0))
        return (LargeDocument.chunk(containing: probe, line: para, in: text, limit: limit), para.length <= limit)
    }

    private func element(for r: NSRange, in storage: NSTextStorage, whole: Bool) -> NSTextElement? {
        if let c = cache[r.location], c.range == r { return c.element }
        let doc = documentRange.location
        guard let s = location(doc, offsetBy: r.location), let e = location(s, offsetBy: r.length) else { return nil }
        if whole {
            // A line that isn't cut: TextKit's own paragraph (its own
            // caching and height estimates; ours made scrolling a
            // many-line large file snap back).
            var native: NSTextElement?
            _ = super.enumerateTextElements(from: s, options: []) { native = $0; return false }
            if let native, let nr = native.elementRange, nr.location.compare(s) == .orderedSame, nr.endLocation.compare(e) == .orderedSame {
                return native
            }
        }
        let p = ChunkParagraph(attributedString: storage.attributedSubstring(from: r))
        p.elementRange = NSTextRange(location: s, end: e)
        // The content range is the chunk without its trailing line break
        // ("\n" or "\r\n", as TextKit's own paragraphs), if any.
        let text = storage.string as NSString
        var sepLength = 0
        if r.length > 0, text.character(at: NSMaxRange(r) - 1) == 10 {
            sepLength = r.length > 1 && text.character(at: NSMaxRange(r) - 2) == 13 ? 2 : 1
        }
        if sepLength > 0, let ce = location(s, offsetBy: r.length - sepLength) {
            p.content = NSTextRange(location: s, end: ce)
            p.separator = NSTextRange(location: ce, end: e)
        } else {
            p.content = p.elementRange
            p.separator = NSTextRange(location: e)
        }
        p.textContentManager = self
        cache[r.location] = (r, p)
        return p
    }

    override func enumerateTextElements(from textLocation: NSTextLocation?, options: NSTextContentManager.EnumerationOptions = [],
                                        using block: (NSTextElement) -> Bool) -> NSTextLocation? {
        guard let limit = chunkLimit, let storage = textStorage, storage.length > 0 else {
            return super.enumerateTextElements(from: textLocation, options: options, using: block)
        }
        let text = storage.string as NSString
        let len = text.length
        let reverse = options.contains(.reverse)
        if reverse {
            // As NSTextContentStorage: backwards from nil hands out nothing.
            guard let textLocation else { return documentRange.location }
            // From a location, backwards: the element ending at or containing it.
            var at = min(self.offset(from: documentRange.location, to: textLocation), len) - 1
            while at >= 0 {
                let (r, whole) = chunkRange(at: at, in: text, limit: limit)
                // Only the chunk holding `at`: never one after it.
                guard let next = LargeDocument.backwardStep(from: at, chunk: r) else { return location(documentRange.location, offsetBy: at + 1) }
                guard let p = element(for: r, in: storage, whole: whole) else { return nil }
                if !block(p) { return p.elementRange?.location }
                at = next
            }
            return documentRange.location
        }
        // Forwards: the element holding the location, then the ones after
        // it. From the end there is none (as NSTextContentStorage): never
        // an element that ends at or before the location asked from.
        var at = max(0, min(textLocation.map { self.offset(from: documentRange.location, to: $0) } ?? 0, len))
        while at < len {
            let (r, whole) = chunkRange(at: at, in: text, limit: limit)
            // Only the chunk holding `at`, so the walk always moves on.
            // One ending at `at` (a boundary moved back for an emoji or an
            // accent, before 0.5.4) had TextKit ask from `at` again, forever.
            guard let next = LargeDocument.forwardStep(from: at, chunk: r) else { return location(documentRange.location, offsetBy: at) }
            guard let p = element(for: r, in: storage, whole: whole) else { return nil }
            if !block(p) { return p.elementRange?.endLocation }
            at = next
        }
        return documentRange.endLocation
    }
}

/// A chunk: TextKit reads the content and separator ranges of a paragraph
/// it lays out, which NSTextContentStorage only fills in for paragraphs it
/// made itself.
final class ChunkParagraph: NSTextParagraph {
    var content: NSTextRange?
    var separator: NSTextRange?
    override var paragraphContentRange: NSTextRange? { content }
    override var paragraphSeparatorRange: NSTextRange? { separator }
}

