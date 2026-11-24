import AppKit
import CedricCore

/// CEDRIC_CHECK=splittyping: typing in a chunked large-mode tab right after
/// the split is closed. The QA monkey's hang, cut down to its nine steps
/// (0.5.4 QA, seeds 213314022/213314023): Base64 Encode a 5 MB log (one
/// 7 M-character line), undo, redo, type, Add Next Occurrence, split,
/// unsplit, type, type. TextKit fixes the selection up from inside the
/// edit (NSTextContentStorage synchronizeTextLayoutManagers), the window
/// tells the owl the caret moved, and the owl used to ask the primary pane
/// for its visible characters there: NSTextLayoutManager
/// ensureLayoutForBounds walked the chunks from inside the edit and never
/// came back. A watchdog thread fails the check (instead of hanging) when
/// the main thread stops answering for 10 s.
extension DevChecks {
    static func splitTypingCheck(_ app: AppDelegate) {
        Settings.shared.owlOverride = true
        OwlController.assumeVisible = true
        final class Ping: @unchecked Sendable { let lock = NSLock(); var last = Date(); var step = "open" }
        let ping = Ping()
        Thread {
            while true {
                DispatchQueue.main.async { ping.lock.withLock { ping.last = Date() } }
                Thread.sleep(forTimeInterval: 0.25)
                let (since, step) = ping.lock.withLock { (Date().timeIntervalSince(ping.last), ping.step) }
                if since > 10 {
                    print("check: FAIL the main thread is stuck (\(Int(since)) s without answering) after: \(step)")
                    print("check: done (watchdog: the passes so far aren't counted), 1 failed")
                    fflush(stdout)
                    exit(1)
                }
            }
        }.start()
        func mark(_ s: String) { ping.lock.withLock { ping.step = s } }

        var log = ""
        log.reserveCapacity(5_300_000)
        var i = 0
        while log.utf8.count < 5 * 1024 * 1024 {
            log += "2026-11-24T10:\(String(format: "%02d:%02d", (i / 60) % 60, i % 60)).\(String(format: "%03d", i % 1000))Z INFO worker-\(i % 16) request id=\(i) status=\(i % 17 == 0 ? 500 : 200) path=/api/items/\(i % 977)\n"
            i += 1
        }
        guard let tab = app.open(write("server.log", log)) else { expect(false, "open"); finish(); return }
        sized(tab)
        var timings: [String: Double] = [:]
        func timed(_ name: String, _ f: () -> Void) {
            mark(name)
            let t0 = DevHooks.now()
            f()
            timings[name] = (DevHooks.now() - t0) * 1000
        }
        run([
            sync {
                tab.window?.makeKeyAndOrderFront(nil)
                tab.window?.makeFirstResponder(tab.textView)
                tab.textView.setSelectedRange(NSRange(location: 0, length: 0))
                timed("Base64 Encode") { tab.applyTextTool(.base64Encode) }
            },
            sync { timed("undo") { key("z", [.command]) } },
            sync { timed("redo") { key("z", [.command, .shift]) } },
            sync {
                expect(tab.textView.contentStorage?.chunkLimit == LargeDocument.chunkLength, "the 7 M-character line is in chunks (large mode)",
                       String(describing: tab.textView.contentStorage?.chunkLimit))
                timed("type") { type("qexcarzrpya") }
            },
            sync { timed("Add Next Occurrence") { tab.textView.addNextOccurrence() } },
            sync { timed("split") { tab.toggleSplit() } },
            sync {
                timed("unsplit") { tab.toggleSplit() }
                expect(!tab.isSplit && tab.window?.firstResponder === tab.primaryTextView, "unsplit: the primary pane has the focus")
            },
            sync { timed("type after unsplit") { type("etydolljwp") } },
            sync { timed("one more key") { key("k") } },
            { next in
                // The owl's caret check, put off until the edit is over, has run.
                DispatchQueue.main.async { next() }
            },
            sync {
                mark("checks")
                expect(true, "typing after the unsplit came back (no hang)")
                expect(tab.text.hasSuffix("etydolljwpk"), "the typed text is there", String(tab.text.suffix(16)))
                for name in ["type after unsplit", "one more key"] {
                    let ms = timings[name] ?? .infinity
                    expect(ms < 250, "\(name) takes under 250 ms", String(format: "%.0f ms", ms))
                }
                // The owl still keeps out of the caret's way: its faded state
                // matches where the caret is now (asked outside any edit).
                if let owl = tab.owl, let window = tab.window {
                    let tv = tab.primaryTextView
                    let sel = tv.selectedRange()
                    let screen = tv.firstRect(forCharacterRange: NSRange(location: NSMaxRange(sel), length: 0), actualRange: nil)
                    let caret = owl.overlay.convert(window.convertFromScreen(screen), from: nil)
                    let near = screen != .zero && caret.insetBy(dx: -28, dy: -18).intersects(owl.owl.frame)
                    expect(owl.owlFaded == near, "the owl's fade follows the caret", "faded \(owl.owlFaded), caret near \(near)")
                } else {
                    expect(false, "the owl is on")
                }
                for (k, v) in timings.sorted(by: { $0.key < $1.key }) { print(String(format: "check: note: %@ %.0f ms", k, v)) }
                tab.doc.markSaved()
            },
        ], gap: 0.1)
    }
}
