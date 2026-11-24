// Scripts/chunks-check.sh compiles this with the app's ChunkedContentStorage
// and CedricCore's LargeDocument and LineIndex (no app, no window on screen).
//
// 1. With chunks on and every line short, ChunkedContentStorage enumerates
//    exactly like NSTextContentStorage: same elements, same returned
//    location, from every offset, forwards and backwards, and from nil.
//    (It handed out the last line forwards from the end; macOS 26 crashed
//    in layout there: 0.5.2's big logs, and a big log after a long-line
//    paste.)
// 2. With long lines cut into chunks: from every offset the elements are
//    contiguous, hold their offset, reach the ends, are no longer than the
//    limit, and their text is the storage's, after edits too (the cache).
// 3. A many-line text in a TextKit 2 text view (in a window that is never
//    shown) gets a 30,000-character line pasted, chunks turn on, and TextKit
//    lays out the top and the end and measures the end.
import AppKit

var failures = 0
func expect(_ ok: Bool, _ what: String, _ detail: @autoclosure () -> String = "") {
    if ok { print("chunks-check: PASS \(what)") } else { failures += 1; print("chunks-check: FAIL \(what) \(detail())") }
}

final class Probe: ChunkedContentStorage {
    var index = LineIndex()
    override init() {
        super.init()
        // As the editor: the line index, when it matches the text.
        lineRange = { [unowned self] offset in
            guard self.index.length == self.textStorage?.length else { return nil }
            let l = self.index.line(containing: offset)
            return NSRange(location: self.index.starts[l], length: self.index.lineLength(l))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    func reindex() { index = LineIndex(textStorage!.string as NSString) }
    /// NSTextContentStorage's own enumeration.
    func native(_ loc: NSTextLocation?, _ o: NSTextContentManager.EnumerationOptions, _ b: (NSTextElement) -> Bool) -> NSTextLocation? {
        let saved = chunkLimit
        chunkLimit = nil
        defer { chunkLimit = saved }
        return enumerateTextElements(from: loc, options: o, using: b)
    }
    func off(_ l: NSTextLocation?) -> Int { l.map { offset(from: documentRange.location, to: $0) } ?? -1 }
    func range(_ e: NSTextElement) -> NSRange? {
        guard let r = e.elementRange else { return nil }
        return NSRange(location: off(r.location), length: offset(from: r.location, to: r.endLocation))
    }
    func at(_ o: Int) -> NSTextLocation? { location(documentRange.location, offsetBy: o) }
}

func storage(_ text: String) -> Probe {
    let cs = Probe()
    cs.textStorage = NSTextStorage(string: text)
    cs.addTextLayoutManager(NSTextLayoutManager())
    cs.reindex()
    return cs
}

// MARK: 1. Short lines: the same as NSTextContentStorage

do {
    var diffs: [String] = []
    let texts = ["abc\ndef\nghi\n", "abc\ndef\nghi", "a\n\n\nb\n", "\n", "x", "ab\r\ncd\r\n", "one line, no newline at all",
                 String(repeating: "2026-11-24 INFO worker request status=200\n", count: 40)]
    for text in texts {
        let cs = storage(text)
        let len = (text as NSString).length
        func compare(_ loc: NSTextLocation?, _ name: String, _ opts: NSTextContentManager.EnumerationOptions, take: Int) {
            var a: [NSRange?] = [], b: [NSRange?] = []
            let ra = cs.native(loc, opts) { a.append(cs.range($0)); return a.count < take }
            cs.chunkLimit = 10_000
            let rb = cs.enumerateTextElements(from: loc, options: opts) { b.append(cs.range($0)); return b.count < take }
            cs.chunkLimit = nil
            if a != b || cs.off(ra) != cs.off(rb) {
                diffs.append("\(text.debugDescription.prefix(30)) from \(name) \(opts.contains(.reverse) ? "backwards" : "forwards") take \(take): "
                             + "native \(a.map { $0.map { "\($0.location)+\($0.length)" } ?? "nil" }) → \(cs.off(ra)), "
                             + "chunked \(b.map { $0.map { "\($0.location)+\($0.length)" } ?? "nil" }) → \(cs.off(rb))")
            }
        }
        for opts: NSTextContentManager.EnumerationOptions in [[], [.reverse]] {
            for take in [1, 2, 1_000] {
                compare(nil, "nil", opts, take: take)
                for o in 0...len { compare(cs.at(o), "\(o)", opts, take: take) }
            }
        }
    }
    expect(diffs.isEmpty, "short lines: the same elements and end locations as NSTextContentStorage, from every offset and nil",
           "\(diffs.count) differences, first: \(diffs.prefix(3).joined(separator: " | "))")
}

// MARK: 2. Long lines in chunks: contiguous, in bounds, fresh after edits

do {
    let limit = 64
    let cs = storage("")
    cs.chunkLimit = limit
    var problems: [String] = []
    func check(_ step: String) {
        let text = cs.textStorage!.string as NSString
        let len = text.length
        func walk(_ loc: NSTextLocation?, reverse: Bool) -> (ranges: [NSRange], ok: Bool) {
            var out: [NSRange] = [], ok = true
            _ = cs.enumerateTextElements(from: loc, options: reverse ? [.reverse] : []) { e in
                guard let r = cs.range(e), r.length > 0, NSMaxRange(r) <= len, (e as? NSTextParagraph)?.attributedString.string == text.substring(with: r)
                else { ok = false; return false }
                out.append(r)
                return true
            }
            return (out, ok)
        }
        for o in stride(from: 0, through: len, by: max(1, len / 400)) {
            let f = walk(cs.at(o), reverse: false)
            let fOK = f.ok && (o == len ? f.ranges.isEmpty : (f.ranges.first.map { NSLocationInRange(o, $0) } ?? false) && NSMaxRange(f.ranges.last!) == len)
                && zip(f.ranges, f.ranges.dropFirst()).allSatisfy { NSMaxRange($0) == $1.location }
                // A boundary moved back for a composed sequence makes the next chunk a little longer.
                && f.ranges.allSatisfy { $0.length <= limit + 8 }
            let b = walk(cs.at(o), reverse: true)
            let bOK = b.ok && (o == 0 ? b.ranges.isEmpty : (b.ranges.first.map { NSLocationInRange(o - 1, $0) } ?? false) && b.ranges.last?.location == 0)
                && zip(b.ranges, b.ranges.dropFirst()).allSatisfy { NSMaxRange($1) == $0.location }
            if !fOK || !bOK { problems.append("\(step): from \(o) \(fOK ? "" : "forwards") \(bOK ? "" : "backwards")"); return }
        }
        var none = 0
        _ = cs.enumerateTextElements(from: nil, options: [.reverse]) { _ in none += 1; return true }
        if none != 0 { problems.append("\(step): \(none) elements backwards from nil") }
    }
    let ts = cs.textStorage!
    func edit(_ range: NSRange, _ s: String, _ step: String) {
        ts.replaceCharacters(in: range, with: s)
        cs.reindex()
        check(step)
    }
    let short = (0..<30).map { "line \($0) of short text\n" }.joined()
    edit(NSRange(location: 0, length: 0), short, "short lines")
    let long = String(repeating: "0123456789abcdef", count: 40)  // 640, ten chunks
    edit(NSRange(location: ts.length, length: 0), long + "\n", "a long line pasted at the end")
    edit(NSRange(location: ts.length, length: 0), "tail without newline", "text after it, no final newline")
    let longStart = (ts.string as NSString).range(of: long).location
    edit(NSRange(location: longStart + 100, length: 0), "INSERTED", "typing inside the long line")
    edit(NSRange(location: longStart + 10, length: 300), "", "deleting most of the long line")
    edit(NSRange(location: 5, length: 0), "é👍🏽e\u{301}" + String(repeating: "w", count: 200) + "\n", "a long line with composed characters near the top")
    edit(NSRange(location: ts.length - 3, length: 3), "", "deleting at the end")
    edit(NSRange(location: 0, length: 0), String(repeating: "z", count: 130) + "\r\n", "a long CRLF line at the top")
    var lastOfCRLF: NSTextParagraph?
    _ = cs.enumerateTextElements(from: cs.at(129)) { lastOfCRLF = $0 as? NSTextParagraph; return false }
    if let p = lastOfCRLF, let sep = p.paragraphSeparatorRange, cs.offset(from: sep.location, to: sep.endLocation) != 2 {
        problems.append("CRLF: the separator isn't \\r\\n")
    }
    edit(NSRange(location: 0, length: ts.length), "", "everything deleted")
    edit(NSRange(location: 0, length: 0), long, "only a long line, no newline")
    expect(problems.isEmpty, "long lines in chunks: contiguous, in bounds, fresh text, nothing forwards from the end, after 12 edits",
           problems.prefix(3).joined(separator: " | "))
}

// MARK: 3. Layout: a many-line text gets a long line, chunks on

do {
    _ = NSApplication.shared
    let lines = Int(CommandLine.arguments.dropFirst().first ?? "") ?? 60_000
    var s = ""
    s.reserveCapacity(lines * 80)
    for i in 0..<lines { s += "2026-11-24T01:36:37.\(String(format: "%06d", i % 1_000_000))Z INFO worker-\(i % 32) request id=\(i) status=200\n" }
    let tlm = NSTextLayoutManager()
    let cs = Probe()
    cs.addTextLayoutManager(tlm)
    let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    container.widthTracksTextView = true
    tlm.textContainer = container
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
    tv.isRichText = false
    tv.isVerticallyResizable = true
    tv.isHorizontallyResizable = false
    let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    scroll.documentView = tv
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: true)
    window.contentView = scroll   // never ordered front
    let ts = tv.textStorage!
    ts.setAttributedString(NSAttributedString(string: s, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)]))
    cs.reindex()
    func layOut() {
        window.layoutIfNeeded()
        tlm.textViewportLayoutController.layoutViewport()
        let doc = cs.documentRange, len = cs.off(doc.endLocation)
        for (a, b) in [(0, 20_000), (max(0, len - 60_000), len)] {
            if let s = cs.at(a), let e = cs.at(min(b, len)), let r = NSTextRange(location: s, end: e) { tlm.ensureLayout(for: r) }
        }
        // What estimatedSizeForLastTextContainer does: segments at the end.
        tlm.enumerateTextSegments(in: NSTextRange(location: doc.endLocation), type: .standard, options: []) { _, _, _, _ in true }
        if let s = cs.at(max(0, len - 5_000)), let r = NSTextRange(location: s, end: doc.endLocation) {
            tlm.enumerateTextSegments(in: r, type: .standard, options: []) { _, _, _, _ in true }
        }
        _ = tlm.usageBoundsForTextContainer
    }
    layOut()
    tv.setSelectedRange(NSRange(location: ts.length, length: 0))
    tv.insertText("xyz", replacementRange: tv.selectedRange())
    let longLine = String(repeating: "0123456789abcdef", count: 1_875)   // 30,000 characters
    tv.insertText("\n" + longLine + "\n", replacementRange: tv.selectedRange())
    cs.reindex()
    layOut()
    // The editor's next-turn step (applyLargeMode): chunks on, layout dropped.
    cs.chunkLimit = 2_048
    tlm.invalidateLayout(for: cs.documentRange)
    layOut()
    var lastFragment: NSRange?
    tlm.enumerateTextLayoutFragments(from: cs.documentRange.endLocation, options: [.reverse, .ensuresLayout]) { f in
        lastFragment = f.textElement.flatMap(cs.range); return false
    }
    expect(lastFragment.map(NSMaxRange) == ts.length && (lastFragment?.length ?? .max) <= 2_048,
           "a pasted 30,000-character line in \(lines) lines: chunks laid out to the end", String(describing: lastFragment))
    for k in 0..<10 {
        tv.setSelectedRange(NSRange(location: ts.length - 2 - k * 2_500, length: 0))
        tv.insertText("q", replacementRange: tv.selectedRange())
        cs.reindex()
        layOut()
    }
    tv.setSelectedRange(NSRange(location: ts.length, length: 0))
    tv.insertText("end", replacementRange: tv.selectedRange())
    cs.reindex()
    layOut()
    expect(ts.string.hasSuffix("\nend"),
           "typing in the chunks and at the end, laid out each time")
}

print(failures == 0 ? "chunks-check: done, 0 failed" : "chunks-check: done, \(failures) failed")
exit(failures == 0 ? 0 : 1)
