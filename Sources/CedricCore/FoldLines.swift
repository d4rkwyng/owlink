import Foundation

// Line questions about folds, for an editor's gutter and menus (the iOS
// FoldingController; the Mac keeps its own copies in CedricApp/Folding.swift).

extension FoldRegion {
    /// The characters the region hides: from the start of the line after
    /// its header to the end of its last line (newline included); nil when
    /// it would hide nothing or runs past `index`.
    public func hiddenRange(in index: LineIndex) -> NSRange? {
        guard header >= 0, header + 1 < index.lineCount, last < index.lineCount, last > header else { return nil }
        let start = index.starts[header + 1]
        let end = last + 1 < index.lineCount ? index.starts[last + 1] : index.length
        return end > start ? NSRange(location: start, length: end - start) : nil
    }
}

extension FoldState {
    /// Header line of each fold (the line before its hidden text), ascending, once each.
    public func headerLines(_ index: LineIndex) -> [Int] {
        // Folds are already ordered; consecutive ranges that share a
        // header are adjacent, so last is enough (as on the Mac).
        var out: [Int] = []
        for f in folds where f.location > 0 && f.location <= index.length {
            let l = index.line(containing: f.location - 1)
            if out.last != l { out.append(l) }
        }
        return out
    }

    /// The folds whose header is `line`.
    public func folds(header line: Int, _ index: LineIndex) -> [NSRange] {
        folds.filter { $0.location > 0 && $0.location <= index.length && index.line(containing: $0.location - 1) == line }
    }

    /// The folds starting where `hidden` starts: a pill's outermost folds
    /// (an inner fold with another start stays folded).
    public func folds(startingAt location: Int) -> [NSRange] {
        folds.filter { $0.location == location }
    }

    /// Whether line `line` is in hidden text (its start is).
    public func isLineHidden(_ line: Int, _ index: LineIndex) -> Bool {
        guard !isEmpty, line >= 0, line < index.lineCount else { return false }
        return isHidden(index.starts[line])
    }

    /// A hidden line's header (the nearest visible line above); a visible line itself.
    public func visibleLine(_ line: Int, _ index: LineIndex) -> Int {
        guard !isEmpty, line >= 0, line < index.lineCount,
              let h = hiddenRange(containing: index.starts[line]), h.location > 0 else { return line }
        return index.line(containing: h.location - 1)
    }

    /// How many lines a hidden range holds (the "⋯ N lines" pill).
    public static func lineCount(of hidden: NSRange, _ index: LineIndex) -> Int {
        guard hidden.length > 0 else { return 0 }
        let a = index.line(containing: hidden.location)
        let b = index.line(containing: max(hidden.location, NSMaxRange(hidden) - 1))
        return b - a + 1
    }
}
