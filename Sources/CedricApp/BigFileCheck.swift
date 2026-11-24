import AppKit
import CedricCore

/// CEDRIC_CHECK=bigfile: a 55 MB log of ordinary lines (0.5.2 crashed in
/// TextKit layout opening any log past 25 M characters on macOS 26: large
/// mode handed TextKit every line through ChunkedContentStorage). Opens
/// it, checks large mode is on without chunks (TextKit's own paragraphs),
/// lays out the top and the end, types at the end, then pastes a 30,000-
/// character line: chunks turn on and TextKit's elements stay contiguous,
/// with ranges, forwards and backwards across the long line. Scripts/
/// bigfile-check.sh generates the log (CEDRIC_BIGFILE=path) and fails on
/// a crash report too; without CEDRIC_BIGFILE the check writes its own.
extension DevChecks {
    static func bigFileCheck(_ name: String, _ app: AppDelegate) -> Bool {
        guard name == "bigfile" else { return false }
        let url: URL
        if let path = DevEnvironment.values["CEDRIC_BIGFILE"] {
            url = URL(fileURLWithPath: path)
        } else {
            url = dir.appendingPathComponent("big.log")
            var s = ""
            s.reserveCapacity(58_000_000)
            var i = 0
            while s.utf8.count < 57_671_757 {
                s += "2026-11-24T01:36:37.\(String(format: "%06d", i % 1_000_000))Z INFO worker-\(i % 32) request id=\(i) status=200 path=/api/v1/items/\(i % 977)\n"
                i += 1
            }
            try? s.write(to: url, atomically: false, encoding: .utf8)
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        expect(size >= 50 * 1024 * 1024, "the log is over 50 MiB", "\(size) bytes")
        let t0 = DevHooks.now()
        guard let tab = app.open(url) else { expect(false, "opened \(url.lastPathComponent)"); finish(); return true }
        sized(tab)
        tab.window?.makeKeyAndOrderFront(nil)
        tab.window?.displayIfNeeded()
        print(String(format: "check: note: opened and drawn in %.0f ms", (DevHooks.now() - t0) * 1000))
        let longLine = String(repeating: "0123456789abcdef", count: 1_875)   // 30,000 characters

        /// TextKit's elements from `offset` (forwards or backwards), up to
        /// `limit` of them: each has a range, and each starts where the
        /// previous one ended. Returns the ranges as offsets.
        func walk(from offset: Int, reverse: Bool, limit: Int) -> [NSRange]? {
            guard let cs = tab.textView.contentStorage, let start = cs.location(cs.documentRange.location, offsetBy: offset) else { return nil }
            var out: [NSRange] = []
            var ok = true
            _ = cs.enumerateTextElements(from: start, options: reverse ? [.reverse] : []) { e in
                guard let r = e.elementRange else { ok = false; return false }
                let s = cs.offset(from: cs.documentRange.location, to: r.location), l = cs.offset(from: r.location, to: r.endLocation)
                out.append(NSRange(location: s, length: l))
                return out.count < limit
            }
            guard ok else { return nil }
            let ordered = reverse ? out.reversed() : out
            for (a, b) in zip(ordered, ordered.dropFirst()) where NSMaxRange(a) != b.location { return nil }
            return Array(ordered)
        }
        func layOutEnd() {
            tab.textView.scrollToEndOfDocument(nil)
            tab.window?.displayIfNeeded()
            if let tlm = tab.textView.textLayoutManager { _ = tlm.usageBoundsForTextContainer }
        }

        run([
            sync {
                expect(tab.isLargeDocument && tab.largeReason == .size, "large mode on (size)", String(describing: tab.largeReason))
                expect(tab.textView.contentStorage?.chunkLimit == nil, "no chunks: TextKit's own paragraphs for short lines")
                expect((tab.text as NSString).length == tab.lineIndex.length && tab.lineIndex.lineCount > 500_000,
                       "the whole text is loaded", "\(tab.lineIndex.lineCount) lines")
                layOutEnd()
                let len = (tab.text as NSString).length
                let back = walk(from: len, reverse: true, limit: 50)
                expect(back != nil && back?.last.map(NSMaxRange) == len, "elements at the end are contiguous and reach the end")
                tab.textView.scrollToBeginningOfDocument(nil)
                tab.window?.displayIfNeeded()
                expect(walk(from: 0, reverse: false, limit: 50)?.first?.location == 0, "elements at the top are contiguous")
            },
            sync {
                tab.window?.makeFirstResponder(tab.textView)
                let len = (tab.text as NSString).length
                tab.textView.setSelectedRange(NSRange(location: len, length: 0))
                tab.reveal(tab.textView.selectedRange())
                for c in "xyz" { key(String(c)) }
                tab.window?.displayIfNeeded()
                expect(tab.text.hasSuffix("xyz"), "typing at the end lands", String(tab.text.suffix(8)))
                // A pasted long line: chunks turn on (next turn).
                tab.textView.insertText("\n" + longLine + "\n", replacementRange: tab.textView.selectedRange())
            },
            sync {
                expect(tab.textView.contentStorage?.chunkLimit == LargeDocument.chunkLength, "a pasted 30,000-character line turns chunks on")
                layOutEnd()
                let len = (tab.text as NSString).length
                let start = len - (longLine as NSString).length - 1
                let fwd = walk(from: start - 200, reverse: false, limit: 100)
                expect(fwd != nil && fwd?.last.map(NSMaxRange) == len, "forwards across the long line: contiguous to the end",
                       fwd.map { "\($0.count) elements" } ?? "a gap or a nil range")
                expect(fwd?.allSatisfy { $0.length <= LargeDocument.chunkLength } == true, "…in chunks no longer than the limit")
                let back = walk(from: len, reverse: true, limit: 100)
                expect(back != nil && back?.last.map(NSMaxRange) == len && (back?.first?.location ?? len) < start,
                       "backwards from the end: contiguous past the long line's start")
                tab.textView.scrollToBeginningOfDocument(nil)
                tab.window?.displayIfNeeded()
                layOutEnd()
                expect(tab.window?.isVisible == true, "still up after laying out top and end")
            },
            snapshot("bigfile-end.png"),
        ])
        return true
    }
}
